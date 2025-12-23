// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./StakeEngine.sol";

/// @title ScoreEngine
/// @notice Computes base and effective Veracity Score (VS) for claims.
/// @dev
/// - baseVSRay: local stake only (support vs. challenge on the claim itself)
/// - effectiveVSRay: multi-hop contextual VS, aggregating incoming support/challenge links
///   from independent claims, using their own effectiveVS recursively.
///
/// All VS values are expressed in "ray" fixed-point format: 1e18 == 1.0.
///
/// Symmetry rules (locked):
/// - Support and challenge are treated symmetrically.
/// - A negative independent VS inverts the meaning of link support/challenge.
/// - Only VS == 0 is neutral (no contribution); there is no "positive-only" gate.
contract ScoreEngine {
    PostRegistry public immutable registry;
    LinkGraph public immutable graph;
    StakeEngine public immutable stake;

    error NotAClaim();

    constructor(address registry_, address graph_, address stake_) {
        registry = PostRegistry(registry_);
        graph = LinkGraph(graph_);
        stake = StakeEngine(stake_);
    }

    // -----------------------------
    // Public views
    // -----------------------------

    /// @notice Base VS for a claim, using only local support/challenge stakes.
    /// @dev
    /// Let S = support stake, C = challenge stake.
    /// VS = (S - C) / (S + C), in ray.
    /// If S + C == 0, returns 0.
    function baseVSRay(uint256 claimPostId) public view returns (int256) {
        _requireClaim(claimPostId);

        (uint256 s, uint256 c) = stake.getPostTotals(claimPostId);
        uint256 t = s + c;
        if (t == 0) return 0;

        int256 net = int256(s) - int256(c);
        return (net * 1e18) / int256(t);
    }

    /// @notice Effective VS for a claim, including multi-hop contextual influence.
    /// @dev
    /// This is the VS used for economic gains/losses:
    /// - Starts with the claim's own local stake.
    /// - For each incoming link from an independent claim:
    ///     - Uses the *effective* VS of the independent claim (recursive).
    ///     - Weights the link stake by that VS and by the link's support/challenge.
    ///
    /// Graph is assumed acyclic (DAG) so recursion is well-defined.
    function effectiveVSRay(uint256 claimPostId) external view returns (int256) {
        _requireClaim(claimPostId);
        return _effectiveVSRay(claimPostId);
    }

    // -----------------------------
    // Internal recursive engine
    // -----------------------------

    /// @dev Recursive effective VS computation over the DAG.
    ///      Assumes `claimPostId` is a claim (checked by the public entrypoint).
    function _effectiveVSRay(uint256 claimPostId) internal view returns (int256) {
        // Start from local (direct) stake on this claim.
        (uint256 s0, uint256 c0) = stake.getPostTotals(claimPostId);
        int256 netEff = int256(s0) - int256(c0);
        uint256 totEff = s0 + c0;

        // Aggregate contributions from all incoming links.
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(claimPostId);

        for (uint256 i = 0; i < inc.length; i++) {
            uint256 from = inc[i].fromClaimPostId;
            uint256 linkPostId = inc[i].linkPostId;

            // Independent must be a claim (graph should enforce this, but keep it safe).
            (, , PostRegistry.ContentType tFrom, ) = registry.getPost(from);
            if (tFrom != PostRegistry.ContentType.Claim) continue;

            // Multi-hop: use effective VS of the independent claim.
            int256 indVS = _effectiveVSRay(from); // [-1e18, +1e18]

            // Perfectly neutral independent claim contributes nothing (symmetric).
            if (indVS == 0) continue;

            // Link stake (support vs challenge on the link post itself).
            (uint256 ls, uint256 lc) = stake.getPostTotals(linkPostId);
            int256 linkNet = int256(ls) - int256(lc);
            if (linkNet == 0) continue;

            // Confirm link post + fetch canonical link metadata.
            (, , PostRegistry.ContentType lt, uint256 linkContentId) = registry.getPost(linkPostId);
            if (lt != PostRegistry.ContentType.Link) continue;

            (, , bool isChallenge) = registry.getLink(linkContentId);

            // contribNet = (linkNet * indVS) / 1e18
            // This is signed and fully symmetric: negative VS inverts contribution.
            int256 contribNet = (linkNet * indVS) / 1e18;

            // Challenge-links invert the contribution direction.
            if (isChallenge) {
                contribNet = -contribNet;
            }

            // Magnitude contribution (always non-negative), used to normalize.
            uint256 contribMag =
                (uint256(_abs(linkNet)) * uint256(_abs(indVS))) / 1e18;

            netEff += contribNet;
            totEff += contribMag;
        }

        if (totEff == 0) {
            return 0;
        }

        // netEff is guaranteed within [-totEff, +totEff] because each term obeys |net| <= mag.
        return (netEff * 1e18) / int256(totEff);
    }

    // -----------------------------
    // Internal helpers
    // -----------------------------

    function _requireClaim(uint256 postId) internal view {
        (, , PostRegistry.ContentType t, ) = registry.getPost(postId);
        if (t != PostRegistry.ContentType.Claim) revert NotAClaim();
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }
}
