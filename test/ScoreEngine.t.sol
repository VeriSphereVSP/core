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

        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp = new MockVSP();
        stake = new StakeEngine(address(vsp));
        score = new ScoreEngine(address(registry), address(stake), address(graph));

        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    // Activate a post without saturating VS to ±1
    function _activateNeutral(uint256 postId) internal {
        stake.stake(postId, stake.SIDE_SUPPORT(), 1);
        stake.stake(postId, stake.SIDE_CHALLENGE(), 1);
    }

    // Stake a link with mass but non-saturated VS (~ +0.5)
    function _stakeLinkBiased(uint256 linkPostId, uint256 total) internal {
        // 3/4 support, 1/4 challenge
        uint256 s = (total * 3) / 4;
        uint256 d = total - s;
        stake.stake(linkPostId, stake.SIDE_SUPPORT(), s);
        stake.stake(linkPostId, stake.SIDE_CHALLENGE(), d);
    }

    // ------------------------------------------------------------
    // A -> B -> C linear propagation
    // ------------------------------------------------------------
    function test_MultiHopEffectiveVS_LinearChain() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        _activateNeutral(B);
        _activateNeutral(C);

        stake.stake(A, stake.SIDE_SUPPORT(), 300);

        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        _stakeLinkBiased(AB, 400);
        _stakeLinkBiased(BC, 400);

        int256 evsA = score.effectiveVSRay(A);
        int256 evsB = score.effectiveVSRay(B);
        int256 evsC = score.effectiveVSRay(C);

        assertGt(evsA, 0);
        assertGt(evsB, 0);
        assertGt(evsC, 0);

        assertGe(evsA, evsB);
        assertGe(evsB, evsC);

        assertTrue(evsC >= -RAY && evsC <= RAY);
    }

    // ------------------------------------------------------------
    // Challenge propagation
    // ------------------------------------------------------------
    function test_MultiHopWithChallengePropagation() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        _activateNeutral(B);
        _activateNeutral(C);

        stake.stake(A, stake.SIDE_SUPPORT(), 300);

        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, true);

        _stakeLinkBiased(AB, 400);
        _stakeLinkBiased(BC, 400);

        int256 evsB = score.effectiveVSRay(B);
        int256 evsC = score.effectiveVSRay(C);

        assertGt(evsB, 0);
        assertLt(evsC, evsB);
    }

    // ------------------------------------------------------------
    // Upstream flip must move downstream
    // ------------------------------------------------------------
    function test_MultiHopMixedInfluence() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        _activateNeutral(B);
        _activateNeutral(C);

        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        _stakeLinkBiased(AB, 800);
        _stakeLinkBiased(BC, 800);

        stake.stake(A, stake.SIDE_SUPPORT(), 300);
        int256 eC1 = score.effectiveVSRay(C);

        stake.stake(A, stake.SIDE_CHALLENGE(), 1200);
        int256 eC2 = score.effectiveVSRay(C);

        assertTrue(eC1 != eC2);
        assertTrue(eC2 < eC1);
    }

    // ------------------------------------------------------------
    // IC mass evenly distributed
    // ------------------------------------------------------------
    function test_ICMass_DistributesEvenlyAcrossEqualLinks() public {
        uint256 IC = registry.createClaim("IC");
        uint256 D1 = registry.createClaim("D1");
        uint256 D2 = registry.createClaim("D2");

        _activateNeutral(D1);
        _activateNeutral(D2);

        stake.stake(IC, stake.SIDE_SUPPORT(), 500);

        uint256 L1 = registry.createLink(IC, D1, false);
        uint256 L2 = registry.createLink(IC, D2, false);

        _stakeLinkBiased(L1, 400);
        _stakeLinkBiased(L2, 400);

        int256 v1 = score.effectiveVSRay(D1);
        int256 v2 = score.effectiveVSRay(D2);

        int256 diff = v1 - v2;
        if (diff < 0) diff = -diff;

        assertLe(uint256(diff), 1e12);
    }

    // ------------------------------------------------------------
    // Larger link mass dominates
    // ------------------------------------------------------------
    function test_ICMass_StrongerLinkGetsMoreInfluence() public {
        uint256 IC = registry.createClaim("IC");
        uint256 D1 = registry.createClaim("D1");
        uint256 D2 = registry.createClaim("D2");

        _activateNeutral(D1);
        _activateNeutral(D2);

        stake.stake(IC, stake.SIDE_SUPPORT(), 500);

        uint256 L1 = registry.createLink(IC, D1, false);
        uint256 L2 = registry.createLink(IC, D2, false);

        _stakeLinkBiased(L1, 400);
        _stakeLinkBiased(L2, 100);

        int256 v1 = score.effectiveVSRay(D1);
        int256 v2 = score.effectiveVSRay(D2);

        assertGt(v1, v2);
    }
}

