// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./StakeEngine.sol";
import "./ScoreEngine.sol";

/// @title ProtocolViews
/// @notice Read-only aggregation over PostRegistry + StakeEngine + LinkGraph + ScoreEngine.
///         No storage; no mutation; deterministic output.
contract ProtocolViews {
    PostRegistry public immutable registry;
    StakeEngine public immutable stake;
    LinkGraph public immutable graph;
    ScoreEngine public immutable score;

    struct ClaimSummary {
        uint256 postId;
        address creator;
        uint256 version;
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
        stake = StakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
    }

    // ------------------------------------------------------------------------
    // Claim summary
    // ------------------------------------------------------------------------

    function getClaimSummary(uint256 claimPostId)
        external
        view
        returns (ClaimSummary memory summary)
    {
        (
            address creator,
            uint256 version,
            PostRegistry.ContentType ct,
            uint256 contentId
        ) = registry.getPost(claimPostId);

        require(ct == PostRegistry.ContentType.Claim, "ProtocolViews: not claim");

        string memory text = registry.getClaim(contentId);

        (uint256 supportStake, uint256 challengeStake) =
            stake.getPostTotals(claimPostId);

        int256 baseVS = score.baseVSRay(claimPostId);
        int256 effectiveVS = score.effectiveVSRay(claimPostId);

        uint256 incomingCount =
            graph.getIncoming(claimPostId).length;

        uint256 outgoingCount =
            graph.getOutgoing(claimPostId).length;

        summary = ClaimSummary({
            postId: claimPostId,
            creator: creator,
            version: version,
            text: text,
            supportStake: supportStake,
            challengeStake: challengeStake,
            baseVSRay: baseVS,
            effectiveVSRay: effectiveVS,
            incomingCount: incomingCount,
            outgoingCount: outgoingCount
        });
    }

    // ------------------------------------------------------------------------
    // Raw VS passthroughs
    // ------------------------------------------------------------------------

    /// @notice Raw base VS in ray (1e18 = +1.0, -1e18 = -1.0).
    function getBaseVSRay(uint256 claimPostId) external view returns (int256) {
        return score.baseVSRay(claimPostId);
    }

    /// @notice Raw effective VS in ray (multi-hop, symmetrical).
    function getEffectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return score.effectiveVSRay(claimPostId);
    }

    // ------------------------------------------------------------------------
    // Graph passthroughs
    // ------------------------------------------------------------------------

    function getOutgoingEdges(uint256 claimPostId)
        external
        view
        returns (LinkGraph.Edge[] memory)
    {
        return graph.getOutgoing(claimPostId);
    }

    function getIncomingEdges(uint256 claimPostId)
        external
        view
        returns (LinkGraph.IncomingEdge[] memory)
    {
        return graph.getIncoming(claimPostId);
    }

    /// @notice Resolve link metadata for a link post id.
    function getLinkMeta(uint256 linkPostId)
        external
        view
        returns (
            uint256 independentClaimPostId,
            uint256 dependentClaimPostId,
            bool isChallenge
        )
    {
        (
            ,
            ,
            PostRegistry.ContentType ct,
            uint256 contentId
        ) = registry.getPost(linkPostId);

        require(ct == PostRegistry.ContentType.Link, "ProtocolViews: not link");

        (independentClaimPostId, dependentClaimPostId, isChallenge) =
            registry.getLink(contentId);
    }
}

