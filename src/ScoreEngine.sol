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
/// @notice Computes Verity Scores for claims using stake-weighted evidence propagation.
///
/// Key rules:
///   1. Only credible parents contribute: parentVS must be > 0.
///      A discredited claim (VS ≤ 0) has no influence through its outgoing links.
///   2. Contributions are stake-weighted: the parent's economic mass (VS × totalStake)
///      flows through links, not just a percentage.
///   3. The child's effective VS is computed from the combined pool of direct stakes
///      plus incoming contributions.
contract ScoreEngine is GovernedUpgradeable {
    using SafeCast for uint256;

    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    IPostingFeePolicy public feePolicy;
    IClaimActivityPolicy public activityPolicy;

    int256 internal constant RAY = 1e18;
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

    /// @notice Base Verity Score from direct stakes only.
    ///
    /// Formula:
    ///   support > challenge:  VS = +(support / total) × RAY
    ///   challenge > support:  VS = −(challenge / total) × RAY
    ///   equal or zero:        VS = 0
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

    function effectiveVSRay(uint256 postId) external view returns (int256) {
        uint256[] memory computing = new uint256[](MAX_DEPTH + 1);
        return _effectiveVSRay(postId, computing, 0);
    }

    /// @notice Effective VS including stake-weighted evidence link contributions.
    ///
    /// For each incoming link to this claim:
    ///   1. Compute parent's effective VS (recursive). Skip if parentVS ≤ 0.
    ///   2. parentMass = parentVS × parentTotalStake / RAY  (token units, always positive)
    ///   3. linkShare = linkStake / sumOutgoingLinkStake     (ratio, unitless)
    ///   4. contribution = parentMass × linkShare × linkVS / RAY
    ///   5. If isChallenge: contribution = -contribution
    ///
    /// Then:
    ///   totalSupport = directSupport + sum(positive contributions)
    ///   totalChallenge = directChallenge + abs(sum(negative contributions))
    ///   effectiveVS = (totalSupport - totalChallenge) / (totalSupport + totalChallenge) × RAY
    function _effectiveVSRay(
        uint256 postId,
        uint256[] memory computing,
        uint256 depth
    ) internal view returns (int256) {
        if (depth > MAX_DEPTH) return 0;

        (uint256 directSupport, uint256 directChallenge) = stake.getPostTotals(
            postId
        );
        uint256 directTotal = directSupport + directChallenge;
        if (!activityPolicy.isActive(directTotal)) return 0;

        // Cycle detection
        for (uint256 i = 0; i < depth; i++) {
            if (computing[i] == postId) {
                return baseVSRay(postId);
            }
        }
        computing[depth] = postId;

        // Accumulate incoming link contributions
        int256 netContribution = 0;

        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 fee = feePolicy.postingFeeVSP();

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            uint256 parentTotal = _totalStake(e.fromClaimPostId);
            if (!activityPolicy.isActive(parentTotal)) continue;

            uint256 linkStake = _totalStake(e.linkPostId);
            if (!activityPolicy.isActive(linkStake)) continue;

            // Get parent's effective VS (recursive)
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

            // RULE: Only credible parents contribute.
            // A discredited claim (VS ≤ 0) is inert — its outgoing links
            // have no effect until the community rehabilitates it with
            // direct support stakes.
            if (parentVS <= 0) continue;

            // Parent economic mass = parentVS × parentTotalStake / RAY
            // parentVS is in [0, RAY], parentTotal is in wei
            // Result is in wei (token units), always positive
            int256 parentMass = (parentVS * parentTotal.toInt256()) / RAY;

            // Distribute across outgoing links proportionally
            uint256 sumOutgoing = _sumOutgoingLinkStake(e.fromClaimPostId, fee);
            if (sumOutgoing == 0) continue;

            int256 contrib = (parentMass * linkStake.toInt256()) /
                sumOutgoing.toInt256();

            // Apply the link's own VS (credibility of the evidence relationship)
            int256 linkVS = baseVSRay(e.linkPostId);
            if (linkVS <= 0) continue; // Discredited links contribute nothing

            contrib = (contrib * linkVS) / RAY;

            // Challenge links flip the sign
            if (e.isChallenge) contrib = -contrib;

            netContribution += contrib;
        }

        // Compute effective VS from direct stakes + contributions
        int256 totalSupport = directSupport.toInt256();
        int256 totalChallenge = directChallenge.toInt256();

        if (netContribution > 0) {
            totalSupport += netContribution;
        } else if (netContribution < 0) {
            totalChallenge += (-netContribution);
        }

        int256 pool = totalSupport + totalChallenge;
        if (pool == 0) return 0;

        int256 vs = ((totalSupport - totalChallenge) * RAY) / pool;
        return _clampRay(vs);
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
