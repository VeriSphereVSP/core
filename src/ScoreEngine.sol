// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IPostingFeePolicy.sol";
import "./interfaces/IClaimActivityPolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract ScoreEngine is GovernedUpgradeable {
    using SafeCast for uint256;

    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    IPostingFeePolicy public feePolicy;
    IClaimActivityPolicy public activityPolicy;

    int256 internal constant RAY = 1e18;
    int256 internal constant MAX_SAFE_INT = type(int128).max;

    constructor() {
        _disableInitializers();
    }

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

    function baseVSRay(uint256 postId) public view returns (int256) {
        PostRegistry.Post memory p = registry.getPost(postId);
        (uint256 A, uint256 D) = stake.getPostTotals(postId);
        uint256 fee = p.creationFee;

        uint256 T = A + D;
        if (T < fee) return 0;

        uint256 Aeff = A + fee;
        uint256 Teff = Aeff + D;
        if (Teff == 0) return 0;

        int256 aeffInt = Aeff > uint256(MAX_SAFE_INT) ? MAX_SAFE_INT : Aeff.toInt256();
        int256 teffInt = Teff > uint256(MAX_SAFE_INT) ? MAX_SAFE_INT : Teff.toInt256();

        int256 vs = ((aeffInt * 2 * RAY) / teffInt) - RAY;
        return _clampRay(vs);
    }

    function effectiveVSRay(uint256 postId) external view returns (int256) {
        return _effectiveVSRay(postId, 0);
    }

    function _effectiveVSRay(uint256 postId, uint256 depth) internal view returns (int256) {
        if (depth > 32) return 0;

        uint256 totalStake = _totalStake(postId);
        if (!activityPolicy.isActive(totalStake)) return 0;

        int256 acc = baseVSRay(postId);
        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(postId);
        uint256 fee = feePolicy.postingFeeVSP();

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            if (!activityPolicy.isActive(_totalStake(e.fromClaimPostId))) continue;
            if (!activityPolicy.isActive(_totalStake(e.linkPostId))) continue;

            int256 parentVS = _effectiveVSRay(e.fromClaimPostId, depth + 1);
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

    function _sumOutgoingLinkStake(uint256 claimPostId, uint256 fee) internal view returns (uint256 sum) {
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

