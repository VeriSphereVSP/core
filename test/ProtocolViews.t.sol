// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";
import "../src/interfaces/IVSPToken.sol";
import "../src/governance/PostingFeePolicy.sol";
import "./mocks/MockVSP.sol";

contract ProtocolViewsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views;

    MockVSP vsp;
    PostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();

        feePolicy = new PostingFeePolicy(address(0), 50);

        registry = new PostRegistry(address(vsp), address(feePolicy));

        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        stake = new StakeEngine(address(vsp));

        score = new ScoreEngine(
            address(registry),
            address(stake),
            address(graph),
            address(feePolicy)
        );

        views = new ProtocolViews(
            address(registry),
            address(stake),
            address(graph),
            address(score),
            address(feePolicy)
        );

        // Fund + approve everything
        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
        vsp.approve(address(registry), type(uint256).max); // Critical for createClaim
    }

    function test_ActivationGate() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 10);
        assertFalse(views.isActive(c));

        stake.stake(c, 0, 40);
        assertTrue(views.isActive(c));
    }

    function test_ClaimSummaryAndRawRays() public {
        uint256 a = registry.createClaim("Drug X is safe");

        ProtocolViews.ClaimSummary memory s0 = views.getClaimSummary(a);
        assertEq(s0.text, "Drug X is safe");
        assertEq(s0.supportStake, 0);
        assertEq(s0.challengeStake, 0);
        assertEq(s0.totalStake, 0);
        assertEq(s0.postingFee, 50);
        assertFalse(s0.isActive);
        assertEq(s0.baseVSRay, 0);
        assertEq(s0.effectiveVSRay, 0);
        assertEq(s0.incomingCount, 0);
        assertEq(s0.outgoingCount, 0);

        stake.stake(a, 0, 49);
        ProtocolViews.ClaimSummary memory s1 = views.getClaimSummary(a);
        assertEq(s1.supportStake, 49);
        assertEq(s1.totalStake, 49);
        assertFalse(s1.isActive);
        assertEq(s1.baseVSRay, 0);
        assertEq(s1.effectiveVSRay, 0);

        stake.stake(a, 0, 1);
        ProtocolViews.ClaimSummary memory s2 = views.getClaimSummary(a);
        assertEq(s2.supportStake, 50);
        assertEq(s2.totalStake, 50);
        assertTrue(s2.isActive);
        assertEq(s2.baseVSRay, 1e18);
        assertEq(s2.effectiveVSRay, 1e18);
    }

    function test_OutgoingIncomingEdgesContainMetadata() public {
        uint256 ic = registry.createClaim("Study S showed minimal adverse effects from drug X");
        uint256 dc = registry.createClaim("Drug X is safe");

        uint256 linkPostId = registry.createLink(ic, dc, false);

        LinkGraph.Edge[] memory out = views.getOutgoingEdges(ic);
        assertEq(out.length, 1);
        assertEq(out[0].toClaimPostId, dc);
        assertEq(out[0].linkPostId, linkPostId);
        assertEq(out[0].isChallenge, false);

        LinkGraph.IncomingEdge[] memory inc = views.getIncomingEdges(dc);
        assertEq(inc.length, 1);
        assertEq(inc[0].fromClaimPostId, ic);
        assertEq(inc[0].linkPostId, linkPostId);
        assertEq(inc[0].isChallenge, false);

        (uint256 indep, uint256 dep, bool isChal) = views.getLinkMeta(linkPostId);
        assertEq(indep, ic);
        assertEq(dep, dc);
        assertEq(isChal, false);
    }

    function test_RawRayPassthroughsMatchScoreEngine() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        stake.stake(dc, 0, 50);
        stake.stake(ic, 0, 100);

        uint256 linkPostId = registry.createLink(ic, dc, false);
        stake.stake(linkPostId, 0, 50);

        int256 bvsViews = views.getBaseVSRay(dc);
        int256 evsViews = views.getEffectiveVSRay(dc);

        int256 bvsScore = score.baseVSRay(dc);
        int256 evsScore = score.effectiveVSRay(dc);

        assertEq(bvsViews, bvsScore);
        assertEq(evsViews, evsScore);
    }
}
