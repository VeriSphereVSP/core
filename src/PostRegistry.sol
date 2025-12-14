// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract PostRegistry {
    struct Post {
        address creator;
        uint256 timestamp;
        string text;
        int256 targetPostId; // 0 = assertion, >0 support, <0 challenge
    }

    /// @dev postId => Post
    mapping(uint256 => Post) private posts;

    /// @dev monotonically increasing post ID
    uint256 public nextPostId;

    event PostCreated(
        uint256 indexed postId,
        address indexed creator,
        int256 targetPostId
    );

    error InvalidPost();

    /// -----------------------------------------------------------------------
    /// Create Post
    /// -----------------------------------------------------------------------

    function createPost(
        string calldata text,
        int256 targetPostId
    ) external returns (uint256 postId) {
        bool hasText = bytes(text).length > 0;
        bool isLink = targetPostId != 0;

        // Enforce atomicity:
        // - assertion: text + no target
        // - link: target + no text
        if (hasText == isLink) {
            revert InvalidPost();
        }

        postId = nextPostId++;

        posts[postId] = Post({
            creator: msg.sender,
            timestamp: block.timestamp,
            text: text,
            targetPostId: targetPostId
        });

        emit PostCreated(postId, msg.sender, targetPostId);
    }

    /// -----------------------------------------------------------------------
    /// Views
    /// -----------------------------------------------------------------------

    function getPost(uint256 postId)
        external
        view
        returns (
            address creator,
            uint256 timestamp,
            string memory text,
            int256 target
        )
    {
        Post storage p = posts[postId];
        return (p.creator, p.timestamp, p.text, p.targetPostId);
    }
}
