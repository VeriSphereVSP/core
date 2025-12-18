// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./StakeEngine.sol";
import "./ScoreEngine.sol";

/// @title ProtocolViews
/// @notice Read-only aggregation over PostRegistry + StakeEngine + LinkGraph (+ ScoreEngine).
///         No storage; no mutation; deterministic output.
contract ProtocolViews {
    PostRegistry public immutable registry;
    StakeEngine public immutable stake;
    LinkGraph public immutable graph;
    ScoreEngine public immutable score;

    constructor(address registry_, address stake_, address graph_, address score_) {
        registry = PostRegistry(registry_);
        stake = StakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
    }

    // ---------------------------------------------------------------------
    // VS API
    // ---------------------------------------------------------------------

    /// Base VS in "ray" scale: [-1e18, +1e18]
    /// VS = (support - challenge)/total
    function getBaseVS(uint256 claimPostId) public view returns (int256 vsRay) {
        (uint256 supportTotal, uint256 challengeTotal) = stake.getPostTotals(claimPostId);
        uint256 total = supportTotal + challengeTotal;
        if (total == 0) return 0;

        int256 num = int256(supportTotal) - int256(challengeTotal);
        vsRay = (num * int256(1e18)) / int256(total);
    }

    /// Base VS in display percent-ish: [-100, +100]
    function getBaseVSPercent(uint256 claimPostId) external view returns (int256 vs100) {
        int256 ray = getBaseVS(claimPostId);
        vs100 = (ray * 100) / int256(1e18);
    }

    function getBaseVSComponents(uint256 claimPostId)
        external
        view
        returns (uint256 supportTotal, uint256 challengeTotal, uint256 total, int256 vsRay)
    {
        (supportTotal, challengeTotal) = stake.getPostTotals(claimPostId);
        total = supportTotal + challengeTotal;
        vsRay = total == 0
            ? int256(0)
            : ((int256(supportTotal) - int256(challengeTotal)) * int256(1e18)) / int256(total);
    }

    /// Effective VS uses contextual influence from ScoreEngine.
    function getEffectiveVS(uint256 claimPostId) external view returns (int256 vsRay) {
        return score.effectiveVSRay(claimPostId);
    }

    // ---------------------------------------------------------------------
    // Claim summary
    // ---------------------------------------------------------------------
    function getClaimSummary(uint256 claimPostId)
        external
        view
        returns (
            address creator,
            uint256 timestamp,
            string memory text,
            uint256 supportTotal,
            uint256 challengeTotal,
            int256 baseVsRay
        )
    {
        PostRegistry.ContentType ct;
        uint256 contentId;

        (creator, timestamp, ct, contentId) = registry.getPost(claimPostId);
        require(ct == PostRegistry.ContentType.Claim, "not claim");

        text = registry.getClaim(contentId);
        (supportTotal, challengeTotal) = stake.getPostTotals(claimPostId);
        baseVsRay = getBaseVS(claimPostId);
    }

    // ---------------------------------------------------------------------
    // Link context
    // ---------------------------------------------------------------------
    function getIncomingEdges(uint256 claimPostId) external view returns (LinkGraph.IncomingEdge[] memory) {
        return graph.getIncoming(claimPostId);
    }

    function getOutgoingEdges(uint256 claimPostId) external view returns (LinkGraph.Edge[] memory) {
        return graph.getOutgoing(claimPostId);
    }
}
