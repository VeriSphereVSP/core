// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LinkGraph.sol";
import "./interfaces/IVSPToken.sol";
import "./interfaces/IPostingFeePolicy.sol";
import "./governance/GovernedUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PostRegistry is GovernedUpgradeable {
    enum ContentType { Claim, Link }

    struct Post {
        address creator;
        uint256 timestamp;
        ContentType contentType;
        uint256 contentId;
        uint256 creationFee;
    }

    struct Claim {
        string text;
    }

    struct Link {
        uint256 independentPostId;
        uint256 dependentPostId;
        bool isChallenge;
    }

    mapping(uint256 => Post) private posts;
    Claim[] private claims;
    Link[] private links;

    uint256 public nextPostId;

    LinkGraph public linkGraph;
    IVSPToken public vspToken;
    IPostingFeePolicy public feePolicy;

    event PostCreated(uint256 indexed postId, address indexed creator, ContentType contentType);
    event LinkGraphSet(address indexed linkGraph);
    event FeeBurned(uint256 indexed postId, uint256 feeAmount);

    error InvalidClaim();
    error IndependentPostDoesNotExist();
    error DependentPostDoesNotExist();
    error IndependentMustBeClaim();
    error DependentMustBeClaim();
    error LinkGraphAlreadySet();
    error LinkGraphZeroAddress();
    error LinkGraphNotSet();
    error FeeTransferFailed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address governance_,
        address vspToken_,
        address feePolicy_
    ) external initializer {
        __GovernedUpgradeable_init(governance_);
        vspToken = IVSPToken(vspToken_);
        feePolicy = IPostingFeePolicy(feePolicy_);
    }

    function setLinkGraph(address linkGraph_) external onlyGovernance {
        if (address(linkGraph) != address(0)) revert LinkGraphAlreadySet();
        if (linkGraph_ == address(0)) revert LinkGraphZeroAddress();

        linkGraph = LinkGraph(linkGraph_);
        emit LinkGraphSet(linkGraph_);
    }

    function _chargeFee() internal returns (uint256 fee) {
        fee = feePolicy.postingFeeVSP();
        if (fee == 0) return 0;

        bool ok = IERC20(address(vspToken)).transferFrom(msg.sender, address(this), fee);
        if (!ok) revert FeeTransferFailed();

        vspToken.burn(fee);
        emit FeeBurned(nextPostId, fee);
    }

    function createClaim(string calldata text) external returns (uint256 postId) {
        if (bytes(text).length == 0) revert InvalidClaim();

        uint256 fee = _chargeFee();

        uint256 claimId = claims.length;
        claims.push(Claim({ text: text }));

        postId = nextPostId++;
        posts[postId] = Post({
            creator: msg.sender,
            timestamp: block.timestamp,
            contentType: ContentType.Claim,
            contentId: claimId,
            creationFee: fee
        });

        emit PostCreated(postId, msg.sender, ContentType.Claim);
    }

    function createLink(
        uint256 independentPostId,
        uint256 dependentPostId,
        bool isChallenge
    ) external returns (uint256 postId) {
        if (address(linkGraph) == address(0)) revert LinkGraphNotSet();
        if (!_exists(independentPostId)) revert IndependentPostDoesNotExist();
        if (!_exists(dependentPostId)) revert DependentPostDoesNotExist();

        Post memory indep = posts[independentPostId];
        Post memory dep = posts[dependentPostId];

        if (indep.contentType != ContentType.Claim) revert IndependentMustBeClaim();
        if (dep.contentType != ContentType.Claim) revert DependentMustBeClaim();

        uint256 fee = _chargeFee();

        uint256 linkId = links.length;
        links.push(Link({
            independentPostId: independentPostId,
            dependentPostId: dependentPostId,
            isChallenge: isChallenge
        }));

        postId = nextPostId++;
        posts[postId] = Post({
            creator: msg.sender,
            timestamp: block.timestamp,
            contentType: ContentType.Link,
            contentId: linkId,
            creationFee: fee
        });

        linkGraph.addEdge(independentPostId, dependentPostId, postId, isChallenge);

        emit PostCreated(postId, msg.sender, ContentType.Link);
    }

    function getPost(uint256 postId) external view returns (Post memory) {
        return posts[postId];
    }

    function getClaim(uint256 claimId) external view returns (string memory) {
        return claims[claimId].text;
    }

    function getLink(uint256 linkId) external view returns (Link memory) {
        return links[linkId];
    }

    function _exists(uint256 postId) internal view returns (bool) {
        return postId < nextPostId;
    }

    uint256[50] private __gap;
}

