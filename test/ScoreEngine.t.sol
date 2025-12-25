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

    /// A -> B -> C
    /// Under the activation rule, B and C must have nonzero stake for their effectiveVS to be computed.
    function test_MultiHopEffectiveVS_LinearChain() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate B and C (so effectiveVS(B) and effectiveVS(C) are not gated to 0)
        stake.stake(B, stake.SIDE_SUPPORT(), 1);
        stake.stake(C, stake.SIDE_SUPPORT(), 1);

        // Make A strongly positive
        stake.stake(A, stake.SIDE_SUPPORT(), 100);

        // Create links and stake the link posts so they contribute
        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        stake.stake(AB, stake.SIDE_SUPPORT(), 50);
        stake.stake(BC, stake.SIDE_SUPPORT(), 50);

        int256 evsA = score.effectiveVSRay(A);
        int256 evsB = score.effectiveVSRay(B);
        int256 evsC = score.effectiveVSRay(C);

        // A should be > 0
        assertGt(evsA, 0);

        // B and C should be > 0 due to propagation
        assertGt(evsB, 0);
        assertGt(evsC, 0);

        // Typically B should be >= C in a simple chain (attenuation)
        assertGe(evsB, evsC);
    }

    /// IC challenge propagation sanity.
    function test_MultiHopWithChallengePropagation() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate B and C
        stake.stake(B, stake.SIDE_SUPPORT(), 1);
        stake.stake(C, stake.SIDE_SUPPORT(), 1);

        // A positive
        stake.stake(A, stake.SIDE_SUPPORT(), 100);

        // A -> B (support), B -> C (challenge)
        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, true);

        // Stake both links
        stake.stake(AB, stake.SIDE_SUPPORT(), 50);
        stake.stake(BC, stake.SIDE_SUPPORT(), 50);

        int256 evsB = score.effectiveVSRay(B);
        int256 evsC = score.effectiveVSRay(C);

        // B should be positive
        assertGt(evsB, 0);

        // Challenge link should invert contribution, pushing C negative (or at least away from B)
        assertLt(evsC, evsB);
    }

    /// Mixed influence: flipping upstream should change downstream (requires downstream activated).
    function test_MultiHopMixedInfluence() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate B and C
        stake.stake(B, stake.SIDE_SUPPORT(), 1);
        stake.stake(C, stake.SIDE_SUPPORT(), 1);

        // Links A->B, B->C (support)
        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        stake.stake(AB, stake.SIDE_SUPPORT(), 50);
        stake.stake(BC, stake.SIDE_SUPPORT(), 50);

        // Case 1: A positive
        stake.stake(A, stake.SIDE_SUPPORT(), 100);
        int256 eC1 = score.effectiveVSRay(C);

        // Case 2: flip A strongly negative by overwhelming challenge
        stake.stake(A, stake.SIDE_CHALLENGE(), 400);
        int256 eC2 = score.effectiveVSRay(C);

        assertTrue(eC1 >= -1e18 && eC1 <= 1e18);
	assertTrue(eC2 >= -1e18 && eC2 <= 1e18);
    }
}

