// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./StakeEngine.sol";

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

    function baseVSRay(uint256 claimPostId) public view returns (int256) {
        _requireClaim(claimPostId);

        (uint256 s, uint256 c) = stake.getPostTotals(claimPostId);
        uint256 t = s + c;
        if (t == 0) return 0;

        // vs = (S - C) / (S + C)
        int256 net = int256(s) - int256(c);
        return (net * 1e18) / int256(t);
    }

    function effectiveVSRay(uint256 dependentClaimPostId) external view returns (int256) {
        _requireClaim(dependentClaimPostId);

        (uint256 s0, uint256 c0) = stake.getPostTotals(dependentClaimPostId);
        int256 netEff = int256(s0) - int256(c0);
        uint256 totEff = s0 + c0;

        LinkGraph.IncomingEdge[] memory inc = graph.getIncoming(dependentClaimPostId);

        for (uint256 i = 0; i < inc.length; i++) {
            uint256 from = inc[i].fromPostId;
            uint256 linkPostId = inc[i].linkPostId;

            // Independent must be a claim (graph is claim-only, but keep it safe)
            (, , PostRegistry.ContentType tFrom, ) = registry.getPost(from);
            if (tFrom != PostRegistry.ContentType.Claim) continue;

            int256 indVS = baseVSRay(from);              // [-1e18, +1e18]
            if (indVS == 0) continue;

            (uint256 ls, uint256 lc) = stake.getPostTotals(linkPostId);
            int256 linkNet = int256(ls) - int256(lc);   // signed stake on link post
            if (linkNet == 0) continue;

            // Need link metadata (isChallenge)
            (, , PostRegistry.ContentType lt, uint256 linkContentId) = registry.getPost(linkPostId);
            if (lt != PostRegistry.ContentType.Link) continue;
            (, , bool isChallenge) = registry.getLink(linkContentId);

            // contribNet = linkNet * indVS / 1e18
            int256 contribNet = (linkNet * indVS) / 1e18;

            // flip for challenge-link
            if (isChallenge) contribNet = -contribNet;

            // contribMag = abs(linkNet) * abs(indVS) / 1e18
            uint256 contribMag = (uint256(_abs(linkNet)) * uint256(_abs(indVS))) / 1e18;

            netEff += contribNet;
            totEff += contribMag;
        }

        if (totEff == 0) return 0;

        // netEff is guaranteed within [-totEff, +totEff] because each term obeys |net|<=mag
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
