// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

// This assumes you already have MockVSP in your test suite (as shown in your traces).
import "./mocks/MockVSP.sol";

contract ProtocolViewsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    MockVSP vsp;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views_;

    function setUp() public {
        registry = new PostRegistry();
        graph = new LinkGraph();
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp = new MockVSP();
        stake = new StakeEngine(address(vsp));
        score = new ScoreEngine(address(registry), address(stake), address(graph));

        views_ = new ProtocolViews(address(registry), address(stake), address(graph), address(score));

        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_ClaimSummaryAndRawRays() public {
        uint256 a = registry.createClaim("Drug X is safe");

        ProtocolViews.ClaimSummary memory s0 = views_.getClaimSummary(a);
        assertEq(s0.text, "Drug X is safe");
        assertEq(s0.supportStake, 0);
        assertEq(s0.challengeStake, 0);
        assertEq(s0.baseVSRay, 0);
        assertEq(s0.effectiveVSRay, 0);
        assertEq(s0.incomingCount, 0);
        assertEq(s0.outgoingCount, 0);

        // stake support on claim -> baseVS should move positive
        stake.stake(a, 0, 100);
        ProtocolViews.ClaimSummary memory s1 = views_.getClaimSummary(a);
        assertEq(s1.supportStake, 100);
        assertEq(s1.challengeStake, 0);
        assertEq(s1.baseVSRay, 1e18);     // full support => +1.0 in ray
        assertEq(s1.effectiveVSRay, 1e18);
    }

    function test_OutgoingIncomingEdgesContainMetadata() public {
        uint256 ic = registry.createClaim("Study S showed minimal adverse effects from drug X");
        uint256 dc = registry.createClaim("Drug X is safe");

        uint256 linkPostId = registry.createLink(ic, dc, false);

        LinkGraph.Edge[] memory out = views_.getOutgoingEdges(ic);
        assertEq(out.length, 1);
        assertEq(out[0].toClaimPostId, dc);
        assertEq(out[0].linkPostId, linkPostId);
        assertEq(out[0].isChallenge, false);

        LinkGraph.IncomingEdge[] memory inc = views_.getIncomingEdges(dc);
        assertEq(inc.length, 1);
        assertEq(inc[0].fromClaimPostId, ic);
        assertEq(inc[0].linkPostId, linkPostId);
        assertEq(inc[0].isChallenge, false);

        (uint256 indep, uint256 dep, bool isChal) = views_.getLinkMeta(linkPostId);
        assertEq(indep, ic);
        assertEq(dep, dc);
        assertEq(isChal, false);
    }

    function test_RawRayPassthroughsMatchScoreEngine() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        // make IC positive
        stake.stake(ic, 0, 100);

        // link IC -> DC and stake link positively
        uint256 linkPostId = registry.createLink(ic, dc, false);
        stake.stake(linkPostId, 0, 10);

        int256 bvsViews = views_.getBaseVSRay(dc);
        int256 evsViews = views_.getEffectiveVSRay(dc);

        int256 bvsScore = score.baseVSRay(dc);
        int256 evsScore = score.effectiveVSRay(dc);

        assertEq(bvsViews, bvsScore);
        assertEq(evsViews, evsScore);
    }
}
