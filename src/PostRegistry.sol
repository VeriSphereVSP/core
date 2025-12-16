// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./LinkGraph.sol";

contract PostRegistry {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum ContentType {
        Claim,
        Link
    }

    struct Post {
        address creator;
        uint256 timestamp;
        ContentType contentType;
        uint256 contentId;
    }

    struct Claim {
        string text;
    }

    struct Link {
        uint256 independentPostId;
        uint256 dependentPostId;
        bool isChallenge;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    mapping(uint256 => Post) private posts;

    Claim[] private claims;
    Link[] private links;

    uint256 public nextPostId;

    address public owner;
    LinkGraph public linkGraph;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PostCreated(uint256 indexed postId, address indexed creator, ContentType contentType);
    event LinkGraphSet(address indexed linkGraph);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidClaim();
    error InvalidLink();

    error IndependentPostDoesNotExist();
    error DependentPostDoesNotExist();

    error IndependentMustBeClaim();
    error DependentMustBeClaim();

    error NotOwner();
    error LinkGraphAlreadySet();
    error LinkGraphNotSet();

    // ---------------------------------------------------------------------
    // Constructor / admin
    // ---------------------------------------------------------------------

    constructor() {
        owner = msg.sender;
    }

    function setLinkGraph(address linkGraph_) external {
        if (msg.sender != owner) revert NotOwner();
        if (address(linkGraph) != address(0)) revert LinkGraphAlreadySet();
        if (linkGraph_ == address(0)) revert LinkGraphNotSet();

        linkGraph = LinkGraph(linkGraph_);
        emit LinkGraphSet(linkGraph_);
    }

    // ---------------------------------------------------------------------
    // Post Creation
    // ---------------------------------------------------------------------

    function createClaim(string calldata text)
        external
        returns (uint256 postId)
    {
        if (bytes(text).length == 0) revert InvalidClaim();

        uint256 claimId = claims.length;
        claims.push(Claim({ text: text }));

        postId = nextPostId++;
        posts[postId] = Post({
            creator: msg.sender,
            timestamp: block.timestamp,
            contentType: ContentType.Claim,
            contentId: claimId
        });

        emit PostCreated(postId, msg.sender, ContentType.Claim);
    }

    function createLink(
        uint256 independentPostId,
        uint256 dependentPostId,
        bool isChallenge
    ) external returns (uint256 postId) {
        if (!_exists(independentPostId)) revert IndependentPostDoesNotExist();
        if (!_exists(dependentPostId)) revert DependentPostDoesNotExist();

        if (posts[independentPostId].contentType != ContentType.Claim)
            revert IndependentMustBeClaim();

        if (posts[dependentPostId].contentType != ContentType.Claim)
            revert DependentMustBeClaim();

        if (address(linkGraph) == address(0)) revert LinkGraphNotSet();

        // 🔐 DAG enforcement
        linkGraph.addEdge(independentPostId, dependentPostId);

        uint256 linkId = links.length;
        links.push(
            Link({
                independentPostId: independentPostId,
                dependentPostId: dependentPostId,
                isChallenge: isChallenge
            })
        );

        postId = nextPostId++;
        posts[postId] = Post({
            creator: msg.sender,
            timestamp: block.timestamp,
            contentType: ContentType.Link,
            contentId: linkId
        });

        emit PostCreated(postId, msg.sender, ContentType.Link);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPost(uint256 postId)
        external
        view
        returns (address, uint256, ContentType, uint256)
    {
        Post storage p = posts[postId];
        return (p.creator, p.timestamp, p.contentType, p.contentId);
    }

    function getClaim(uint256 claimId)
        external
        view
        returns (string memory)
    {
        return claims[claimId].text;
    }

    function getLink(uint256 linkId)
        external
        view
        returns (uint256, uint256, bool)
    {
        Link storage l = links[linkId];
        return (l.independentPostId, l.dependentPostId, l.isChallenge);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _exists(uint256 postId) internal view returns (bool) {
        return postId < nextPostId;
    }
}
