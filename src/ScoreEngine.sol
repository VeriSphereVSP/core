// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./StakeEngine.sol";
import "./interfaces/IPostingFeePolicy.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract ScoreEngine {
    using SafeCast for uint256;

    PostRegistry public immutable registry;
    StakeEngine public immutable stake;
    LinkGraph public immutable graph;
    IPostingFeePolicy public immutable feePolicy;

    int256 internal constant RAY = 1e18;
    int256 internal constant MAX_SAFE_INT = type(int128).max; // ~1.7e38, safe for ray ops

    constructor(
        address registry_,
        address stake_,
        address graph_,
        address feePolicy_
    ) {
        registry = PostRegistry(registry_);
        stake = StakeEngine(stake_);
        graph = LinkGraph(graph_);
        feePolicy = IPostingFeePolicy(feePolicy_);
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

        // Safe cast & clamp to prevent overflow
        int256 aeffInt = Aeff > uint256(MAX_SAFE_INT) ? MAX_SAFE_INT : Aeff.toInt256();
        int256 teffInt = Teff > uint256(MAX_SAFE_INT) ? MAX_SAFE_INT : Teff.toInt256();

        int256 num = aeffInt * 2 * RAY;
        int256 vs = (num / teffInt) - RAY;

        return _clampRay(vs);
    }

    function effectiveVSRay(uint256 claimPostId) external view returns (int256) {
        return _effectiveVSRay(claimPostId, 0);
    }

    function _effectiveVSRay(uint256 claimPostId, uint256 depth) internal view returns (int256) {
        if (depth > 32) return 0;

        uint256 fee = feePolicy.postingFeeVSP();

        if (!_isActive(claimPostId, fee)) return 0;

        int256 acc = baseVSRay(claimPostId);

        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(claimPostId);

        for (uint256 i = 0; i < inc.length; i++) {
            LinkGraph.IncomingEdge memory e = inc[i];

            uint256 parentClaim = e.fromClaimPostId;
            uint256 linkPostId = e.linkPostId;

            if (!_isActive(parentClaim, fee)) continue;
            if (!_isActive(linkPostId, fee)) continue;

            int256 parentVS = _effectiveVSRay(parentClaim, depth + 1);
            if (parentVS == 0) continue;

            uint256 sumOutgoing = _sumOutgoingLinkStake(parentClaim, fee);
            if (sumOutgoing == 0) continue;

            uint256 linkStake = _totalStake(linkPostId);
            if (linkStake < fee) continue;

            int256 linkVS = baseVSRay(linkPostId);
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

    function _isActive(uint256 postId, uint256 fee) internal view returns (bool) {
        return _totalStake(postId) >= fee;
    }

    function _sumOutgoingLinkStake(uint256 claimPostId, uint256 fee) internal view returns (uint256 sum) {
        LinkGraph.Edge[] memory outs = graph.getOutgoing(claimPostId);
        for (uint256 i = 0; i < outs.length; i++) {
            uint256 t = _totalStake(outs[i].linkPostId);
            if (t < fee) continue;
            sum += t;
        }
    }

    function _clampRay(int256 x) internal pure returns (int256) {
        if (x > RAY) return RAY;
        if (x < -RAY) return -RAY;
        return x;
    }
}
