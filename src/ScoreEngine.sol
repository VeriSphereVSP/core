// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IPostingFeePolicy.sol";
import "./interfaces/IClaimActivityPolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ScoreEngine
/// @notice Computes Verity Scores (VS) for claims, including evidence propagation.
///         Supports cycles in the link graph: if a node is encountered that is
///         already on the computation stack, its baseVS is used instead of
///         recursing (breaks the cycle cleanly without truncation).
contract ScoreEngine is GovernedUpgradeable {
    using SafeCast for uint256;

    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    IPostingFeePolicy public feePolicy;
    IClaimActivityPolicy public activityPolicy;

    int256 internal constant RAY = 1e18;
    int256 internal constant MAX_SAFE_INT = type(int128).max;
    uint256 internal constant MAX_DEPTH = 32;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(
        address governance_,
        address registry_,
        address stake_,
        address graph_,
        address feePolicy_,
        address activityPolicy_
    ) external initializer {
        __GovernedUpgradeable_init(governance_);
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
        feePolicy = IPostingFeePolicy(feePolicy_);
        activityPolicy = IClaimActivityPolicy(activityPolicy_);
    }

    /**
     * @notice Base Verity Score from direct stakes only.
     *
     * Formula (intuitive):
     *   if support > challenge:  VS = +(support / total) * 100%   → returned as +RAY fraction
     *   if challenge > support:  VS = -(challenge / total) * 100% → returned as -RAY fraction
     *   if equal or zero:        VS = 0
     *
     * Examples (in percentage terms):
     *   3 support, 1 challenge → +75%
     *   0 support, 2 challenge → -100%
     *   5 support, 5 challenge → 0%
     *   1 support, 0 challenge → +100%
     *
     * No creation fee phantom support — VS is purely determined by actual stakes.
     */
    function baseVSRay(uint256 postId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);

        uint256 T = A + D;
        if (T == 0) return 0;

        if (A > D) {
            return int256((A * uint256(RAY)) / T);
        } else if (D > A) {
            return -int256((D * uint256(RAY)) / T);
        } else {
            return 0;
        }
    }

    /**
     * @notice Effective VS including evidence link contributions.
     *         Allocates a fixed-size stack to track nodes being computed,
     *         preventing infinite recursion from cycles.
     */
    function effectiveVSRay(uint256 postId) external view returns (int256) {
        uint256[] memory computing = new uint256[](MAX_DEPTH + 1);
        return _effectiveVSRay(postId, computing, 0);
    }

    /**
     * @notice Recursive effective VS computation with cycle detection.
     *
     * @param postId    The claim to compute effective VS for.
     * @param computing Stack of post IDs currently being computed (ancestor chain).
     * @param depth     Current recursion depth (index into computing array).
     *
     * For each incoming link to this claim:
     *   - If the parent is already on the computing stack → cycle detected,
     *     use parent's baseVS instead of recursing (breaks the cycle).
     *   - Otherwise, recursively compute parent's effectiveVS.
     *   - Contribution = (linkVS * parentVS) * (linkStake / totalOutgoingLinkStake)
     *   - Challenge links flip the linkVS sign.
     */
    function _effectiveVSRay(
        uint256 postId,
        uint256[] memory computing,
        uint256 depth
    ) internal view returns (int256) {
        if (depth > MAX_DEPTH) return 0;

        uint256 totalStake = _totalStake(postId);
        if (!activityPolicy.isActive(totalStake)) return 0;

        // Check if this node is already being computed (cycle)
        for (uint256 i = 0; i < depth; i++) {
            if (computing[i] == postId) {
                // Cycle detected: return baseVS to break the loop.
                // This prevents double-counting while still giving
                // the node a meaningful score from its direct stakes.
                return baseVSRay(postId);
            }
        }

        // Mark this node as being computed
        computing[depth] = postId;

        int256 acc = baseVSRay(postId);
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 fee = feePolicy.postingFeeVSP();

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            if (!activityPolicy.isActive(_totalStake(e.fromClaimPostId)))
                continue;
            if (!activityPolicy.isActive(_totalStake(e.linkPostId))) continue;

            // Check if parent is on the computing stack (would create a cycle).
            // If so, use parent's baseVS directly — don't recurse.
            // This ensures cyclic links still contribute based on direct stakes.
            int256 parentVS;
            bool isCycle = false;
            for (uint256 j = 0; j < depth; j++) {
                if (computing[j] == e.fromClaimPostId) {
                    isCycle = true;
                    break;
                }
            }
            if (isCycle) {
                parentVS = baseVSRay(e.fromClaimPostId);
            } else {
                parentVS = _effectiveVSRay(
                    e.fromClaimPostId,
                    computing,
                    depth + 1
                );
            }
            // Note: we do NOT skip when parentVS == 0. A contested parent with VS=0
            // naturally contributes 0 via the multiplicative formula. Skipping would
            // hide the edge entirely from the computation.
            if (parentVS == 0) continue;

            uint256 sumOutgoing = _sumOutgoingLinkStake(e.fromClaimPostId, fee);
            if (sumOutgoing == 0) continue;

            uint256 linkStake = _totalStake(e.linkPostId);
            if (linkStake < fee) continue;

            int256 linkVS = baseVSRay(e.linkPostId);
            if (e.isChallenge) linkVS = -linkVS;

            int256 contrib = (linkVS * parentVS) / RAY;
            contrib = (contrib * linkStake.toInt256()) / sumOutgoing.toInt256();
            acc += contrib;
        }

        return _clampRay(acc);
    }

    function _totalStake(uint256 postId) internal view returns (uint256) {
        (uint256 s, uint256 d) = stake.getPostTotals(postId);
        return s + d;
    }

    function _sumOutgoingLinkStake(
        uint256 claimPostId,
        uint256 fee
    ) internal view returns (uint256 sum) {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(claimPostId);
        for (uint256 i = 0; i < outs.length; i++) {
            uint256 t = _totalStake(outs[i].linkPostId);
            if (t >= fee) sum += t;
        }
    }

    function _clampRay(int256 x) internal pure returns (int256) {
        if (x > RAY) return RAY;
        if (x < -RAY) return -RAY;
        return x;
    }

    uint256[50] private __gap;
}
