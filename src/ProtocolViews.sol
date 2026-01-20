// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./ScoreEngine.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IPostingFeePolicy.sol";

/// @title ProtocolViews
/// @notice Read-only aggregation layer for UI/indexers.
contract ProtocolViews {
    PostRegistry public immutable registry;
    IStakeEngine public immutable stake;
    LinkGraph public immutable graph;
    ScoreEngine public immutable score;
    IPostingFeePolicy public immutable feePolicy;

    struct ClaimSummary {
        string text;
        uint256 supportStake;
        uint256 challengeStake;
        uint256 totalStake;
        uint256 postingFee;
        bool isActive;
        int256 baseVSRay;
        int256 effectiveVSRay;
        uint256 incomingCount;
        uint256 outgoingCount;
    }

    constructor(
        address registry_,
        address stake_,
        address graph_,
        address score_,
        address feePolicy_
    ) {
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
        feePolicy = IPostingFeePolicy(feePolicy_);
    }

    function getClaimSummary(uint256 claimPostId)
        external
        view
        returns (ClaimSummary memory s)
    {
        PostRegistry.Post memory p = registry.getPost(claimPostId);
        require(p.contentType == PostRegistry.ContentType.Claim, "not claim");

        s.text = registry.getClaim(p.contentId);

        (s.supportStake, s.challengeStake) =
            stake.getPostTotals(claimPostId);

        s.totalStake = s.supportStake + s.challengeStake;
        s.postingFee = feePolicy.postingFeeVSP();
        s.isActive = s.totalStake >= s.postingFee;

        // ScoreEngine already enforces Model B gating
        s.baseVSRay = score.baseVSRay(claimPostId);
        s.effectiveVSRay = score.effectiveVSRay(claimPostId);

        s.incomingCount = graph.getIncoming(claimPostId).length;
        s.outgoingCount = graph.getOutgoing(claimPostId).length;
    }

    // ---------------------------------------------------------------------
    // Passthrough helpers
    // ---------------------------------------------------------------------

    function postingFeeVSP() external view returns (uint256) {
        return feePolicy.postingFeeVSP();
    }

    function isActive(uint256 postId) external view returns (bool) {
        (uint256 s, uint256 c) = stake.getPostTotals(postId);
        return (s + c) >= feePolicy.postingFeeVSP();
    }

    function getBaseVSRay(uint256 postId) external view returns (int256) {
        return score.baseVSRay(postId);
    }

    function getEffectiveVSRay(uint256 postId) external view returns (int256) {
        return score.effectiveVSRay(postId);
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
        PostRegistry.Post memory p = registry.getPost(linkPostId);
        require(p.contentType == PostRegistry.ContentType.Link, "not link");

        PostRegistry.Link memory l = registry.getLink(p.contentId);
        return (l.independentPostId, l.dependentPostId, l.isChallenge);
    }
}

