// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/interfaces/IVSPToken.sol";

contract MockVSP is IVSPToken {
    string private _name = "MockVSP";
    string private _symbol = "mVSP";
    uint8 private constant _decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;

    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function decimals() external pure returns (uint8) { return _decimals; }

    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address owner) external view returns (uint256) { return _bal[owner]; }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(_bal[msg.sender] >= amount, "bal");
        _bal[msg.sender] -= amount;
        _bal[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= amount, "allow");
        require(_bal[from] >= amount, "bal");
        _allow[from][msg.sender] = a - amount;
        _bal[from] -= amount;
        _bal[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _bal[to] += amount;
    }

    function burn(uint256 amount) external {
        require(_bal[msg.sender] >= amount, "bal");
        _bal[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        uint256 a = _allow[from][msg.sender];
        require(a >= amount, "allow");
        require(_bal[from] >= amount, "bal");
        _allow[from][msg.sender] = a - amount;
        _bal[from] -= amount;
        _totalSupply -= amount;
    }
}

contract ScoreEngineTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    MockVSP vsp;
    StakeEngine stake;
    ScoreEngine score;

    int256 internal constant RAY = 1e18;

    function setUp() public {
        registry = new PostRegistry();

        // LinkGraph owner is this test contract
        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp = new MockVSP();
        stake = new StakeEngine(address(vsp));
        score = new ScoreEngine(address(registry), address(stake), address(graph));

        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // A -> B -> C : propagation should be positive and attenuate with hops.
    // Under gating rules, B and C must have nonzero stake or effectiveVS=0.
    // ---------------------------------------------------------------------
    function test_MultiHopEffectiveVS_LinearChain() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate B & C so effectiveVS is computed
        stake.stake(B, stake.SIDE_SUPPORT(), 1);
        stake.stake(C, stake.SIDE_SUPPORT(), 1);

        // Strong A support
        stake.stake(A, stake.SIDE_SUPPORT(), 200);

        // Links A->B, B->C
        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        // Give links meaningful mass so routed influence exists
        stake.stake(AB, stake.SIDE_SUPPORT(), 200);
        stake.stake(BC, stake.SIDE_SUPPORT(), 200);

        int256 evsA = score.effectiveVSRay(A);
        int256 evsB = score.effectiveVSRay(B);
        int256 evsC = score.effectiveVSRay(C);

        assertGt(evsA, 0, "A should be positive");
        assertGt(evsB, 0, "B should receive routed influence");
        assertGt(evsC, 0, "C should receive routed influence");

        // Multi-hop should not amplify: downstream should not exceed upstream in a simple chain
        assertGe(evsA, evsB, "A should be >= B in simple chain");
        assertGe(evsB, evsC, "B should be >= C in simple chain");

        // Still bounded
        assertTrue(evsC >= -RAY && evsC <= RAY, "bounded");
    }

    // ---------------------------------------------------------------------
    // Challenge link should invert contribution polarity.
    // Here: A -> B support, B -> C challenge.
    // Expect: C pulled away from B, potentially negative depending on weights.
    // ---------------------------------------------------------------------
    function test_MultiHopWithChallengePropagation() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate B & C
        stake.stake(B, stake.SIDE_SUPPORT(), 1);
        stake.stake(C, stake.SIDE_SUPPORT(), 1);

        // Strong A support
        stake.stake(A, stake.SIDE_SUPPORT(), 200);

        // A -> B support, B -> C challenge
        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, true);

        // Make both links strong enough to matter
        stake.stake(AB, stake.SIDE_SUPPORT(), 200);
        stake.stake(BC, stake.SIDE_SUPPORT(), 200);

        int256 evsB = score.effectiveVSRay(B);
        int256 evsC = score.effectiveVSRay(C);

        assertGt(evsB, 0, "B should be positive");
        assertTrue(evsC < evsB, "challenge should pull C below B");

        // Depending on your exact math, evsC may or may not go negative.
        // But it MUST remain bounded.
        assertTrue(evsC >= -RAY && evsC <= RAY, "bounded");
    }

    // ---------------------------------------------------------------------
    // Mixed influence: flipping upstream should MOVE downstream if routing is strong enough.
    // Do NOT require a full sign flip; require a meaningful delta and direction.
    // ---------------------------------------------------------------------
    function test_MultiHopMixedInfluence() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate B & C (otherwise effectiveVS=0)
        stake.stake(B, stake.SIDE_SUPPORT(), 1);
        stake.stake(C, stake.SIDE_SUPPORT(), 1);

        // Links A->B, B->C (support)
        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        // Make routing strong
        stake.stake(AB, stake.SIDE_SUPPORT(), 400);
        stake.stake(BC, stake.SIDE_SUPPORT(), 400);

        // Case 1: A positive
        stake.stake(A, stake.SIDE_SUPPORT(), 300);
        int256 eC1 = score.effectiveVSRay(C);

        // Case 2: overwhelm A with challenge to flip A negative hard
        stake.stake(A, stake.SIDE_CHALLENGE(), 1200);
        int256 eC2 = score.effectiveVSRay(C);

        assertTrue(eC1 >= -RAY && eC1 <= RAY, "eC1 bounded");
        assertTrue(eC2 >= -RAY && eC2 <= RAY, "eC2 bounded");

        // Must respond
        assertTrue(eC1 != eC2, "C should change when upstream flips (with strong routing)");

        // Directional expectation: after flipping A negative, C should move downward
        assertTrue(eC2 < eC1, "C should move down when A flips negative");
    }

    // ---------------------------------------------------------------------
    // NEW: IC mass distribution across multiple outgoing links.
    // Equal link mass => equal downstream influence.
    // ---------------------------------------------------------------------
    function test_ICMass_DistributesEvenlyAcrossEqualLinks() public {
        uint256 IC = registry.createClaim("IC");
        uint256 D1 = registry.createClaim("D1");
        uint256 D2 = registry.createClaim("D2");

        // Activate DCs
        stake.stake(D1, stake.SIDE_SUPPORT(), 1);
        stake.stake(D2, stake.SIDE_SUPPORT(), 1);

        // Strong IC
        stake.stake(IC, stake.SIDE_SUPPORT(), 500);

        uint256 L1 = registry.createLink(IC, D1, false);
        uint256 L2 = registry.createLink(IC, D2, false);

        // Equal link stake/mass
        stake.stake(L1, stake.SIDE_SUPPORT(), 200);
        stake.stake(L2, stake.SIDE_SUPPORT(), 200);

        int256 v1 = score.effectiveVSRay(D1);
        int256 v2 = score.effectiveVSRay(D2);

        // They should be very close. Exact equality may not hold due to integer division,
        // but should be within a tiny tolerance.
        int256 diff = v1 - v2;
        if (diff < 0) diff = -diff;

        assertLe(uint256(int256(diff)), 1e12, "equal links should yield ~equal influence");
    }

    // ---------------------------------------------------------------------
    // NEW: Larger link mass should receive more IC mass.
    // ---------------------------------------------------------------------
    function test_ICMass_StrongerLinkGetsMoreInfluence() public {
        uint256 IC = registry.createClaim("IC");
        uint256 D1 = registry.createClaim("D1");
        uint256 D2 = registry.createClaim("D2");

        // Activate DCs
        stake.stake(D1, stake.SIDE_SUPPORT(), 1);
        stake.stake(D2, stake.SIDE_SUPPORT(), 1);

        // Strong IC
        stake.stake(IC, stake.SIDE_SUPPORT(), 500);

        uint256 L1 = registry.createLink(IC, D1, false);
        uint256 L2 = registry.createLink(IC, D2, false);

        // Unequal link mass
        stake.stake(L1, stake.SIDE_SUPPORT(), 400);
        stake.stake(L2, stake.SIDE_SUPPORT(), 100);

        int256 v1 = score.effectiveVSRay(D1);
        int256 v2 = score.effectiveVSRay(D2);

        assertGt(v1, v2, "heavier link should route more IC mass");
    }
}

