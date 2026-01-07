// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./ScoreEngine.sol";
import "./interfaces/IStakeEngine.sol";

/// @title ProtocolViews
/// @notice Read-only aggregation layer for UI/indexers.
contract ProtocolViews {
    PostRegistry public immutable registry;
    IStakeEngine public immutable stake;
    LinkGraph public immutable graph;
    ScoreEngine public immutable score;

    struct ClaimSummary {
        string text;
        uint256 supportStake;
        uint256 challengeStake;
        int256 baseVSRay;
        int256 effectiveVSRay;
        uint256 incomingCount;
        uint256 outgoingCount;
    }

    constructor(
        address registry_,
        address stake_,
        address graph_,
        address score_
    ) {
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
    }

    function getClaimSummary(uint256 claimPostId)
        external
        view
        returns (ClaimSummary memory s)
    {
        (
            ,
            ,
            PostRegistry.ContentType ct,
            uint256 contentId
        ) = registry.getPost(claimPostId);

        require(ct == PostRegistry.ContentType.Claim, "not claim");

        s.text = registry.getClaim(contentId);

        (s.supportStake, s.challengeStake) =
            stake.getPostTotals(claimPostId);

        s.baseVSRay = score.baseVSRay(claimPostId);
        s.effectiveVSRay = score.effectiveVSRay(claimPostId);

        s.incomingCount = graph.getIncoming(claimPostId).length;
        s.outgoingCount = graph.getOutgoing(claimPostId).length;
    }

    // passthrough helpers

    function getBaseVSRay(uint256 claimPostId) external view returns (int256) {
        return score.baseVSRay(claimPostId);
    }

    function getEffectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return score.effectiveVSRay(claimPostId);
    }

    function getIncomingEdges(uint256 claimPostId)
        external
        view
        returns (LinkGraph.IncomingEdge[] memory)
    {
        return graph.getIncoming(claimPostId);
    }

    function getOutgoingEdges(uint256 claimPostId)
        external
        view
        returns (LinkGraph.Edge[] memory)
    {
        return graph.getOutgoing(claimPostId);
    }

    function getLinkMeta(uint256 linkPostId)
        external
        view
        returns (uint256 from, uint256 to, bool isChallenge)
    {
        (
            ,
            ,
            PostRegistry.ContentType ct,
            uint256 linkId
        ) = registry.getPost(linkPostId);

        require(ct == PostRegistry.ContentType.Link, "not link");

        return registry.getLink(linkId);
    }
}

