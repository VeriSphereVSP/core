// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./interfaces/IStakeEngine.sol";

/// @title ScoreEngine
/// @notice Computes base and effective Verity Scores (VS) for claims.
///         VS is represented as signed ray (1e18 = +1.0).
contract ScoreEngine {
    PostRegistry public immutable registry;
    IStakeEngine public immutable stake;
    LinkGraph public immutable graph;

    int256 internal constant RAY = 1e18;

    constructor(
        address registry_,
        address stake_,
        address graph_
    ) {
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
    }

    // ---------------------------------------------------------------------
    // Base VS
    // ---------------------------------------------------------------------

    /// @notice Base VS = (2A / (A + D)) - 1   (ray-scaled)
    /// @dev Posting fee is injected into A *only when active*
    function baseVSRay(uint256 postId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 postingFee = stake.postingFeeThreshold();

        uint256 T = A + D;

        // Always safe on empty.
        if (T == 0) return 0;

        // Economic gating.
        if (T < postingFee) return 0;

        // Inject posting fee as virtual support (only once active)
        uint256 Aeff = A + postingFee;
        uint256 Teff = Aeff + D;

        // Teff can't be 0 here because T>=postingFee and T>0, and Aeff>=A>=0.
        int256 num = int256(2 * Aeff) * RAY;
        int256 vs = (num / int256(Teff)) - RAY;

        return _clampRay(vs);
    }

    // ---------------------------------------------------------------------
    // Effective VS (recursive)
    // ---------------------------------------------------------------------

    function effectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return _effectiveVSRay(claimPostId, 0);
    }

    function _effectiveVSRay(uint256 claimPostId, uint256 depth)
        internal
        view
        returns (int256)
    {
        if (depth > 32) return 0;

        uint256 postingFee = stake.postingFeeThreshold();
        if (!_isActive(claimPostId, postingFee)) return 0;

        int256 acc = baseVSRay(claimPostId);

        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(claimPostId);

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            uint256 ic = e.fromClaimPostId;
            uint256 linkPostId = e.linkPostId;

            if (!_isActive(ic, postingFee)) continue;
            if (!_isActive(linkPostId, postingFee)) continue;

            int256 icVS = _effectiveVSRay(ic, depth + 1);
            if (icVS == 0) continue;

            uint256 sumOutgoing = _sumOutgoingLinkStake(ic, postingFee);
            if (sumOutgoing == 0) continue;

            uint256 linkStake = _totalStake(linkPostId);
            if (linkStake < postingFee) continue;

            int256 linkVS = baseVSRay(linkPostId);
            if (e.isChallenge) linkVS = -linkVS;

            // contrib = (linkVS * icVS) * (linkStake / sumOutgoing)
            int256 contrib = (linkVS * icVS) / RAY;
            contrib = (contrib * int256(linkStake)) / int256(sumOutgoing);

            acc += contrib;
        }

        return _clampRay(acc);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _totalStake(uint256 postId) internal view returns (uint256) {
        (uint256 s, uint256 d) = stake.getPostTotals(postId);
        return s + d;
    }

    function _isActive(uint256 postId, uint256 threshold)
        internal
        view
        returns (bool)
    {
        // If threshold is accidentally set to 0, still treat empty as inactive.
        uint256 t = _totalStake(postId);
        if (t == 0) return false;
        return t >= threshold;
    }

    function _sumOutgoingLinkStake(uint256 ic, uint256 threshold)
        internal
        view
        returns (uint256 sum)
    {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(ic);
        for (uint256 i = 0; i < outs.length; i++) {
            uint256 t = _totalStake(outs[i].linkPostId);
            if (t < threshold) continue;
            sum += t;
        }
    }

    function _clampRay(int256 x) internal pure returns (int256) {
        if (x > RAY) return RAY;
        if (x < -RAY) return -RAY;
        return x;
    }
}

