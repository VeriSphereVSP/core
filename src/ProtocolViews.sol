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

    constructor(address registry_, address stake_, address graph_, address score_) {
        registry = PostRegistry(registry_);
        stake = StakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
    }

    struct ClaimSummary {
        address creator;
        uint32 version;
        string text;
        uint256 supportStake;
        uint256 challengeStake;
        int256 baseVSRay;
        int256 effectiveVSRay;
        uint256 incomingCount;
        uint256 outgoingCount;
    }

    /// @notice Raw baseVS in ray units (1e18-scaled signed fixed point in [-1e18,+1e18])
    function getBaseVSRay(uint256 claimPostId) external view returns (int256) {
        return score.baseVSRay(claimPostId);
    }

    /// @notice Raw effectiveVS in ray units (1e18-scaled signed fixed point in [-1e18,+1e18])
    function getEffectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return score.effectiveVSRay(claimPostId);
    }

    /// @notice Convenience: return claim details + stake totals + scores + edge counts.
    function getClaimSummary(uint256 claimPostId) external view returns (ClaimSummary memory s) {
        // Post metadata
        (address creator, uint32 version, PostRegistry.ContentType ct, ) = registry.getPost(claimPostId);
        require(ct == PostRegistry.ContentType.Claim, "NOT_CLAIM");

        // Claim text
        string memory text = registry.getClaim(claimPostId);

        // Direct stake totals on the claim itself
        (uint256 sup, uint256 cha) = stake.getPostTotals(claimPostId);

        // Scores (raw rays)
        int256 bvs = score.baseVSRay(claimPostId);
        int256 evs = score.effectiveVSRay(claimPostId);

        // Edge counts
        LinkGraph.Edge[] memory out = graph.getOutgoing(claimPostId);
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(claimPostId);

        s = ClaimSummary({
            creator: creator,
            version: version,
            text: text,
            supportStake: sup,
            challengeStake: cha,
            baseVSRay: bvs,
            effectiveVSRay: evs,
            incomingCount: inc.length,
            outgoingCount: out.length
        });
    }

    /// @notice Return outgoing edges for a claim (typed struct array).
    function getOutgoingEdges(uint256 fromClaimPostId) external view returns (LinkGraph.Edge[] memory) {
        return graph.getOutgoing(fromClaimPostId);
    }

    /// @notice Return incoming edges for a claim (typed struct array).
    function getIncomingEdges(uint256 toClaimPostId) external view returns (LinkGraph.IncomingEdge[] memory) {
        return graph.getIncoming(toClaimPostId);
    }

    /// @notice Convenience: return link post metadata for a given link post.
    /// @dev Useful for indexers/clients that get linkPostId from edges.
    function getLinkMeta(uint256 linkPostId)
        external
        view
        returns (uint256 independentClaimPostId, uint256 dependentClaimPostId, bool isChallenge)
    {
        (independentClaimPostId, dependentClaimPostId, isChallenge) = registry.getLink(linkPostId);
    }

    /// @notice Convenience: return link post stake totals (support/challenge) for a given link post.
    function getLinkStakeTotals(uint256 linkPostId) external view returns (uint256 supportStake, uint256 challengeStake) {
        (supportStake, challengeStake) = stake.getPostTotals(linkPostId);
    }
}
