// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IPostingFeePolicy.sol";
import "./interfaces/IClaimActivityPolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ScoreEngine (v2 — bounded fan-in)
/// @notice Computes Verity Scores for claims using stake-weighted evidence propagation.
///
/// Key rules:
///   1. Only credible parents contribute: parentVS must be > 0.
///   2. Contributions are stake-weighted: parent economic mass flows through links.
///   3. Effective VS = (directSupport + positiveContribs - directChallenge - negativeContribs) / pool.
///   4. A claim is active if direct stakes OR abs(incoming contributions) >= posting fee.
///   5. Cycle elimination: when computing VS(X), if a chain of links leads back to X,
///      X's contribution is zero. X cannot influence its own VS through any path.
///
/// v2 changes:
///   - MAX_INCOMING_EDGES: bounds the number of incoming edges processed per claim.
///   - MAX_OUTGOING_LINKS: bounds the outgoing link stake summation per parent.
///   - Both are governance-configurable via setEdgeLimits().
///   - Prevents gas exhaustion on popular claims with many evidence links.
contract ScoreEngine is GovernedUpgradeable {
    using SafeCast for uint256;

    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    IPostingFeePolicy public feePolicy;
    IClaimActivityPolicy public activityPolicy;

    int256 internal constant RAY = 1e18;
    uint256 internal constant MAX_DEPTH = 32;

    // ── New in v2: bounded fan-in ────────────────────────────────
    // These use gap slots (no storage layout change).

    /// @notice Max incoming edges processed per effectiveVSRay call.
    ///         Edges beyond this limit are silently skipped.
    uint256 public maxIncomingEdges;

    /// @notice Max outgoing links summed when computing a parent's
    ///         link stake distribution. Links beyond this are skipped.
    uint256 public maxOutgoingLinks;

    uint256 private constant DEFAULT_MAX_INCOMING = 64;
    uint256 private constant DEFAULT_MAX_OUTGOING = 64;

    event EdgeLimitsSet(uint256 maxIncoming, uint256 maxOutgoing);
    error InvalidEdgeLimit();

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
        maxIncomingEdges = DEFAULT_MAX_INCOMING;
        maxOutgoingLinks = DEFAULT_MAX_OUTGOING;
    }

    // ── Governance ───────────────────────────────────────────────

    /// @notice Set the maximum number of edges processed in VS computation.
    ///         Governance-only. Values of 0 are rejected.
    function setEdgeLimits(
        uint256 maxIncoming_,
        uint256 maxOutgoing_
    ) external onlyGovernance {
        if (maxIncoming_ == 0 || maxOutgoing_ == 0) revert InvalidEdgeLimit();
        maxIncomingEdges = maxIncoming_;
        maxOutgoingLinks = maxOutgoing_;
        emit EdgeLimitsSet(maxIncoming_, maxOutgoing_);
    }

    // ── VS Computation ──────────────────────────────────────────

    function baseVSRay(uint256 postId) public view returns (int256) {
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 T = A + D;
        if (T == 0) return 0;
        if (A > D) return int256((A * uint256(RAY)) / T);
        if (D > A) return -int256((D * uint256(RAY)) / T);
        return 0;
    }

    function effectiveVSRay(uint256 postId) external view returns (int256) {
        uint256[] memory computing = new uint256[](MAX_DEPTH + 1);
        return _effectiveVSRay(postId, computing, 0);
    }

    function _effectiveVSRay(
        uint256 postId,
        uint256[] memory computing,
        uint256 depth
    ) internal view returns (int256) {
        if (depth > MAX_DEPTH) return 0;

        // Cycle detection
        for (uint256 i = 0; i < depth; i++) {
            if (computing[i] == postId) return 0;
        }
        computing[depth] = postId;

        (uint256 directSupport, uint256 directChallenge) = stake.getPostTotals(
            postId
        );
        bool directlyActive = activityPolicy.isActive(
            directSupport + directChallenge
        );

        // Compute incoming link contributions (bounded)
        (
            int256 netContribution,
            uint256 absContribution
        ) = _sumIncomingContributions(postId, computing, depth);

        // Activity gate
        if (!directlyActive && absContribution < feePolicy.postingFeeVSP()) {
            return 0;
        }

        // Combine
        int256 totalSupport = directSupport.toInt256();
        int256 totalChallenge = directChallenge.toInt256();

        if (netContribution > 0) {
            totalSupport += netContribution;
        } else if (netContribution < 0) {
            totalChallenge += (-netContribution);
        }

        int256 pool = totalSupport + totalChallenge;
        if (pool == 0) return 0;

        return _clampRay(((totalSupport - totalChallenge) * RAY) / pool);
    }

    /// @dev Computes the sum of incoming link contributions, bounded by maxIncomingEdges.
    function _sumIncomingContributions(
        uint256 postId,
        uint256[] memory computing,
        uint256 depth
    ) internal view returns (int256 net, uint256 abs_) {
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 fee = feePolicy.postingFeeVSP();

        // Bound: process at most maxIncomingEdges
        uint256 limit = inc.length;
        uint256 maxIn = maxIncomingEdges;
        if (maxIn > 0 && limit > maxIn) limit = maxIn;

        for (uint256 i = 0; i < limit; i++) {
            int256 contrib = _computeEdgeContribution(
                inc[i],
                computing,
                depth,
                fee
            );
            if (contrib != 0) {
                net += contrib;
                abs_ += _abs(contrib);
            }
        }
    }

    /// @dev Computes the contribution of a single incoming edge.
    function _computeEdgeContribution(
        LinkGraph.IncomingEdge memory e,
        uint256[] memory computing,
        uint256 depth,
        uint256 fee
    ) internal view returns (int256) {
        uint256 parentTotal = _totalStake(e.fromClaimPostId);
        if (!activityPolicy.isActive(parentTotal)) return 0;

        uint256 linkStake = _totalStake(e.linkPostId);
        if (!activityPolicy.isActive(linkStake)) return 0;

        // Parent VS (recursive, with cycle detection)
        int256 parentVS = _effectiveVSRay(
            e.fromClaimPostId,
            computing,
            depth + 1
        );
        if (parentVS <= 0) return 0;

        // Link VS
        int256 linkVS = baseVSRay(e.linkPostId);
        if (linkVS <= 0) return 0;

        // Parent mass distributed to this link (bounded outgoing sum)
        uint256 sumOutgoing = _sumOutgoingLinkStake(e.fromClaimPostId, fee);
        if (sumOutgoing == 0) return 0;

        int256 numerator = (parentVS * parentTotal.toInt256() * linkStake.toInt256()) /
            sumOutgoing.toInt256();
        int256 contrib = (numerator * linkVS) / (RAY * RAY);

        if (e.isChallenge) contrib = -contrib;

        return contrib;
    }

    function _totalStake(uint256 postId) internal view returns (uint256) {
        (uint256 s, uint256 d) = stake.getPostTotals(postId);
        return s + d;
    }

    /// @dev Sum outgoing link stakes, bounded by maxOutgoingLinks.
    function _sumOutgoingLinkStake(
        uint256 claimPostId,
        uint256 fee
    ) internal view returns (uint256 sum) {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(claimPostId);

        // Bound: process at most maxOutgoingLinks
        uint256 limit = outs.length;
        uint256 maxOut = maxOutgoingLinks;
        if (maxOut > 0 && limit > maxOut) limit = maxOut;

        for (uint256 i = 0; i < limit; i++) {
            uint256 t = _totalStake(outs[i].linkPostId);
            if (t >= fee) sum += t;
        }
    }

    function _clampRay(int256 x) internal pure returns (int256) {
        if (x > RAY) return RAY;
        if (x < -RAY) return -RAY;
        return x;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    // Reduced gap by 2 for maxIncomingEdges + maxOutgoingLinks
    uint256[48] private __gap;
}
