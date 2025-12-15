// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
        uint256 contentId; // index into claims[] or links[]
    }

    struct Claim {
        string text;
    }

    struct Link {
        uint256 independentPostId; // must be a Claim post
        uint256 dependentPostId;   // must be a Claim post
        bool isChallenge;          // false = support, true = challenge
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// postId => Post
    mapping(uint256 => Post) private posts;

    Claim[] private claims;
    Link[] private links;

    uint256 public nextPostId;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PostCreated(
        uint256 indexed postId,
        address indexed creator,
        ContentType contentType
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error InvalidClaim();
    error InvalidLink();

    error IndependentPostDoesNotExist();
    error DependentPostDoesNotExist();

    error IndependentMustBeClaim();
    error DependentMustBeClaim();

    // ---------------------------------------------------------------------
    // Post Creation
    // ---------------------------------------------------------------------

    /// Create a standalone claim
    function createClaim(string calldata text) external returns (uint256 postId) {
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

    /// Create a link between two existing claims
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
        returns (
            address creator,
            uint256 timestamp,
            ContentType contentType,
            uint256 contentId
        )
    {
        Post storage p = posts[postId];
        return (p.creator, p.timestamp, p.contentType, p.contentId);
    }

    function getClaim(uint256 claimId) external view returns (string memory text) {
        return claims[claimId].text;
    }

    function getLink(uint256 linkId)
        external
        view
        returns (
            uint256 independentPostId,
            uint256 dependentPostId,
            bool isChallenge
        )
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
