// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./StakeEngine.sol";

/// @title ScoreEngine
/// @notice Computes base and effective Veracity Scores (VS) for claims.
///         VS is represented as signed ray (1e18 = +1.0).
///
/// RULES:
/// - baseVS depends only on direct stake
/// - effectiveVS propagates recursively over links
/// - a link contributes ONLY IF:
///     * IC has non-zero stake
///     * DC has non-zero stake
///     * link itself has non-zero stake
/// - symmetry preserved: negative VS propagates normally
contract ScoreEngine {
    PostRegistry public immutable registry;
    StakeEngine public immutable stake;
    LinkGraph public immutable graph;

    int256 internal constant RAY = 1e18;

    constructor(
        address registry_,
        address stake_,
        address graph_
    ) {
        registry = PostRegistry(registry_);
        stake = StakeEngine(stake_);
        graph = LinkGraph(graph_);
    }

    // ---------------------------------------------------------------------
    // Base VS
    // ---------------------------------------------------------------------

    /// @notice Base VS = (2A / (A + D)) - 1
    function baseVSRay(uint256 claimPostId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(claimPostId);
        uint256 T = A + D;
        if (T == 0) return 0;

        // ray math: ((2A / T) - 1) * 1e18
        int256 num = int256(2 * A) * RAY;
        int256 vs = (num / int256(T)) - RAY;

        // clamp safety
        if (vs > RAY) return RAY;
        if (vs < -RAY) return -RAY;
        return vs;
    }

    // ---------------------------------------------------------------------
    // Effective VS (recursive)
    // ---------------------------------------------------------------------

    function effectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return _effectiveVSRay(claimPostId, 0);
    }

    function _effectiveVSRay(
        uint256 claimPostId,
        uint256 depth
    ) internal view returns (int256) {
        // recursion safety
        if (depth > 32) return 0;

        // DC must be economically active
        (uint256 sDC, uint256 dDC) = stake.getPostTotals(claimPostId);
        if (sDC + dDC == 0) {
            return 0;
        }

        int256 baseVS = baseVSRay(claimPostId);
        int256 acc = baseVS;

        LinkGraph.IncomingEdge[] memory inc =
            graph.getIncoming(claimPostId);

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            uint256 ic = e.fromClaimPostId;
            uint256 linkPostId = e.linkPostId;

            // IC must be active
            (uint256 sIC, uint256 dIC) = stake.getPostTotals(ic);
            if (sIC + dIC == 0) continue;

            // link must be active
            (uint256 sL, uint256 dL) = stake.getPostTotals(linkPostId);
            uint256 tL = sL + dL;
            if (tL == 0) continue;

            int256 icVS = _effectiveVSRay(ic, depth + 1);

            // link baseVS
            int256 linkVS;
            {
                int256 num = int256(2 * sL) * RAY;
                linkVS = (num / int256(tL)) - RAY;
            }

            // challenge flips polarity
            if (e.isChallenge) {
                linkVS = -linkVS;
            }

            // contribution = icVS * linkVS
            int256 contrib = (icVS * linkVS) / RAY;

            acc += contrib;
        }

        // clamp
        if (acc > RAY) return RAY;
        if (acc < -RAY) return -RAY;
        return acc;
    }
}

