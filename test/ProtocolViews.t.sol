// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

// Minimal ERC20-ish mock for StakeEngine
contract MockVSP {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    // Added for completeness (StakeEngine uses these during updatePost)
    function burn(uint256 amt) external {
        require(balanceOf[msg.sender] >= amt, "burn");
        balanceOf[msg.sender] -= amt;
    }

    function burnFrom(address from, uint256 amt) external {
        require(allowance[from][msg.sender] >= amt, "allow");
        require(balanceOf[from] >= amt, "burn");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        require(allowance[from][msg.sender] >= amt, "allow");
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ProtocolViewsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views;
    MockVSP vsp;

    function setUp() public {
        graph = new LinkGraph(address(this));

        registry = new PostRegistry();
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp = new MockVSP();
        stake = new StakeEngine(address(vsp));

        score = new ScoreEngine(address(registry), address(graph), address(stake));

        views = new ProtocolViews(address(registry), address(stake), address(graph), address(score));

        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_ClaimSummaryAndBaseVS() public {
        uint256 c0 = registry.createClaim("A");

        (, , , , , int256 vs0) = views.getClaimSummary(c0);
        assertEq(vs0, 0);

        stake.stake(c0, 0, 100);
        int256 vs1 = views.getBaseVS(c0);
        assertEq(vs1, int256(1e18));

        stake.stake(c0, 1, 50);
        int256 vs2 = views.getBaseVS(c0);

        // VS = (100-50)/150 = 1/3 => 1e18/3 (avoid rational-const cast)
        assertEq(vs2, int256(uint256(1e18) / 3));
    }

    function test_IncomingAndOutgoingEdgesContainMetadata() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 linkPostId = registry.createLink(a, b, false);

        LinkGraph.Edge[] memory outA = views.getOutgoingEdges(a);
        assertEq(outA.length, 1);
        assertEq(outA[0].toClaimPostId, b);
        assertEq(outA[0].linkPostId, linkPostId);
        assertEq(outA[0].isChallenge, false);

        LinkGraph.IncomingEdge[] memory inB = views.getIncomingEdges(b);
        assertEq(inB.length, 1);
        assertEq(inB[0].fromClaimPostId, a);
        assertEq(inB[0].linkPostId, linkPostId);
        assertEq(inB[0].isChallenge, false);
    }

    function test_BaseVSPercentScaling() public {
        uint256 c0 = registry.createClaim("A");
        stake.stake(c0, 0, 75);
        stake.stake(c0, 1, 25);

        int256 vsPct = views.getBaseVSPercent(c0);
        assertEq(vsPct, 50);
    }

    function test_EffectiveVS_DelegatesToScoreEngine() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        stake.stake(a, 0, 100);

        uint256 linkPostId = registry.createLink(a, b, false);
        stake.stake(linkPostId, 0, 10);

        int256 eff = views.getEffectiveVS(b);
        assertTrue(eff > 0, "effective VS should be positive");
    }
}
