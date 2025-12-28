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
///     * IC is economically active (totalStake >= postingFeeThreshold)
///     * DC is economically active (totalStake >= postingFeeThreshold)
///     * link itself is economically active (totalStake >= postingFeeThreshold)
/// - symmetry preserved: negative VS propagates normally
///
/// NEW (3.6+ incentive change):
/// - Incoming effect is NOT just icVS * linkVS.
/// - Instead, an IC exports its (effectiveVS(IC)) “mass” across ALL of its outgoing links
///   proportional to each link’s stake (conservation / no amplification):
///
///     let S = sum_{outgoing links of IC} totalStake(link)
///     share(link) = totalStake(link) / S
///
///     incomingEffect(link -> DC) = linkVS * icVS * share(link)
///
///   (and then flipped if edge.isChallenge, which negates linkVS)
contract ScoreEngine {
    PostRegistry public immutable registry;
    StakeEngine public immutable stake;
    LinkGraph public immutable graph;

    int256 internal constant RAY = 1e18;

    constructor(address registry_, address stake_, address graph_) {
        registry = PostRegistry(registry_);
        stake = StakeEngine(stake_);
        graph = LinkGraph(graph_);
    }

    // ---------------------------------------------------------------------
    // Base VS
    // ---------------------------------------------------------------------

    /// @notice Base VS = (2A / (A + D)) - 1   (ray-scaled)
    function baseVSRay(uint256 postId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 T = A + D;
        if (T == 0) return 0;

        // ray math: ((2A / T) - 1) * 1e18
        int256 num = int256(2 * A) * RAY;
        int256 vs = (num / int256(T)) - RAY;

        return _clampRay(vs);
    }

    // ---------------------------------------------------------------------
    // Effective VS (recursive)
    // ---------------------------------------------------------------------

    function effectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return _effectiveVSRay(claimPostId, 0);
    }

    function _effectiveVSRay(uint256 claimPostId, uint256 depth) internal view returns (int256) {
        // recursion safety
        if (depth > 32) return 0;

        uint256 threshold = stake.postingFeeThreshold();

        // DC must be economically active to have meaningful effectiveVS
        if (!_isActive(claimPostId, threshold)) {
            return 0;
        }

        int256 baseVS = baseVSRay(claimPostId);
        int256 acc = baseVS;

        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(claimPostId);

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            uint256 ic = e.fromClaimPostId;
            uint256 linkPostId = e.linkPostId;

            // IC must be economically active
            if (!_isActive(ic, threshold)) continue;

            // Link post must be economically active
            if (!_isActive(linkPostId, threshold)) continue;

            // IC effectiveVS (recursive)
            int256 icVS = _effectiveVSRay(ic, depth + 1);
            if (icVS == 0) continue;

            // Compute sum of ALL outgoing link stakes from IC (distribution denominator)
            uint256 sumOutgoingLinkStake = _sumOutgoingLinkStake(ic, threshold);
            if (sumOutgoingLinkStake == 0) continue;

            // This particular link stake (numerator)
            uint256 linkStake = _totalStake(linkPostId);
            if (linkStake == 0) continue;

            // Link "vote" is the link's own VS (based on its own stake queues)
            // (Links don't have incoming claim-links, so baseVS == effectiveVS for links.)
            int256 linkVS = baseVSRay(linkPostId);

            // challenge edge flips semantic polarity
            if (e.isChallenge) {
                linkVS = -linkVS;
            }

            // incomingEffect = linkVS * icVS * (linkStake / sumOutgoingLinkStake)
            // Keep ray precision:
            //   (linkVS * icVS) / RAY  => ray
            //   then * linkStake / sumOutgoing => ray
            int256 contrib = (linkVS * icVS) / RAY;
            contrib = (contrib * int256(linkStake)) / int256(sumOutgoingLinkStake);

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

    function _isActive(uint256 postId, uint256 threshold) internal view returns (bool) {
        uint256 t = _totalStake(postId);
        if (threshold == 0) {
            return t > 0;
        }
        return t >= threshold;
    }

    /// @dev Sum stakes of ALL outgoing links from IC. (Optional: only count links that are economically active.)
    function _sumOutgoingLinkStake(uint256 icClaimPostId, uint256 threshold) internal view returns (uint256 sum) {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(icClaimPostId);
        for (uint256 i = 0; i < outs.length; i++) {
            uint256 linkPostId = outs[i].linkPostId;
            uint256 t = _totalStake(linkPostId);

            // Only include links that are active; prevents dust from diluting distribution.
            if (threshold == 0) {
                if (t == 0) continue;
            } else {
                if (t < threshold) continue;
            }

            sum += t;
        }
    }

    function _clampRay(int256 x) internal pure returns (int256) {
        if (x > RAY) return RAY;
        if (x < -RAY) return -RAY;
        return x;
    }
}
