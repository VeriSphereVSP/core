// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PostRegistry.sol";
import "./LinkGraph.sol";
import "./ScoreEngine.sol";
import "./interfaces/IStakeEngine.sol";
import "./interfaces/IPostingFeePolicy.sol";
import "./governance/GovernedUpgradeable.sol";

contract ProtocolViews is GovernedUpgradeable {
    PostRegistry public registry;
    IStakeEngine public stake;
    LinkGraph public graph;
    ScoreEngine public score;
    IPostingFeePolicy public feePolicy;

    struct ClaimSummary {
        string text;
        uint256 supportStake;
        uint256 challengeStake;
        uint256 totalStake;
        uint256 postingFee;
        bool isActive;
        int256 baseVSRay;
        int256 effectiveVSRay;
        uint256 incomingCount;
        uint256 outgoingCount;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address governance_,
        address registry_,
        address stake_,
        address graph_,
        address score_,
        address feePolicy_
    ) external initializer {
        __GovernedUpgradeable_init(governance_);
        registry = PostRegistry(registry_);
        stake = IStakeEngine(stake_);
        graph = LinkGraph(graph_);
        score = ScoreEngine(score_);
        feePolicy = IPostingFeePolicy(feePolicy_);
    }

    function getClaimSummary(uint256 claimPostId)
        external
        view
        returns (ClaimSummary memory s)
    {
        PostRegistry.Post memory p = registry.getPost(claimPostId);
        require(p.contentType == PostRegistry.ContentType.Claim, "not claim");

        s.text = registry.getClaim(p.contentId);
        (s.supportStake, s.challengeStake) = stake.getPostTotals(claimPostId);
        s.totalStake = s.supportStake + s.challengeStake;
        s.postingFee = feePolicy.postingFeeVSP();
        s.isActive = s.totalStake >= s.postingFee;
        s.baseVSRay = score.baseVSRay(claimPostId);
        s.effectiveVSRay = score.effectiveVSRay(claimPostId);
        s.incomingCount = graph.getIncoming(claimPostId).length;
        s.outgoingCount = graph.getOutgoing(claimPostId).length;
    }

    function postingFeeVSP() 
    	external 
	view 
	returns (uint256)
    {
        return feePolicy.postingFeeVSP();
    }

    function isActive(uint256 postId) 
        external 
	view 
	returns (bool)
    {
        (uint256 s, uint256 c) = stake.getPostTotals(postId);
        return (s + c) >= feePolicy.postingFeeVSP();
    }

    function getBaseVSRay(uint256 postId) 
        external 
	view 
	returns (int256) 
    {
        return score.baseVSRay(postId);
    }

    function getEffectiveVSRay(uint256 postId) 
        external 
	view 
	returns (int256) 
    {
        return score.effectiveVSRay(postId);
    }

    function getIncomingEdges(uint256 claimPostId)
        external
        view
        returns (LinkGraph.IncomingEdge[] memory)
    {
        return graph.getIncoming(claimPostId);
    }

    function getOutgoingEdges(uint256 claimPostId)
        external
        view
        returns (LinkGraph.Edge[] memory)
    {
        return graph.getOutgoing(claimPostId);
    }

    function getLinkMeta(uint256 linkPostId)
        external
        view
        returns (uint256 from, uint256 to, bool isChallenge)
    {
        PostRegistry.Post memory p = registry.getPost(linkPostId);
        require(p.contentType == PostRegistry.ContentType.Link, "not link");
    
        PostRegistry.Link memory l = registry.getLink(p.contentId);
        return (l.independentPostId, l.dependentPostId, l.isChallenge);
    }

    
    uint256[50] private __gap;
}

