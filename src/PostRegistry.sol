// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    PostRegistry
    ------------
    The canonical on-chain registry of VeriSphere posts ("claims") and links.

    Each post is immutable and includes:
    - creator
    - timestamp
    - text (claim content or link commentary)
    - targetPostId (0 = standalone, >0 = support link, <0 = challenge link)

    This contract:
    - DOES create posts
    - DOES store link intent via targetPostId
    - DOES NOT track stake totals (those live only in StakeEngine)
    - DOES NOT implement verity score logic
    - DOES NOT enforce DAG rules on-chain (handled off-chain)
*/

contract PostRegistry {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PostCreated(uint256 indexed postId, address indexed creator, string text, int256 targetPostId);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error EmptyText();
    error InvalidPostId();

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Post {
        address creator;
        uint256 timestamp;
        string text;
        int256 targetPostId; // 0 = standalone, >0 = support, <0 = challenge
    }

    // Next id to assign (post ids start at 1)
    uint256 public nextPostId = 1;

    // postId => Post
    mapping(uint256 => Post) internal posts;

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor() {
        // No special wiring required for MVP.
    }

    // ---------------------------------------------------------------------
    // Post Creation
    // ---------------------------------------------------------------------

    /// @notice Create a new post or link.
    /// @param text          The human-readable claim text.
    /// @param targetPostId  0 = standalone, >0 = support, <0 = challenge.
    function createPost(string calldata text, int256 targetPostId) external returns (uint256 postId) {
        if (bytes(text).length == 0) revert EmptyText();

        postId = nextPostId;
        nextPostId += 1;

        posts[postId] = Post({creator: msg.sender, timestamp: block.timestamp, text: text, targetPostId: targetPostId});

        emit PostCreated(postId, msg.sender, text, targetPostId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Read a post by id.
    function getPost(uint256 postId)
        external
        view
        returns (address creator, uint256 timestamp, string memory text, int256 targetPostId)
    {
        if (postId == 0 || postId >= nextPostId) revert InvalidPostId();

        Post storage p = posts[postId];
        return (p.creator, p.timestamp, p.text, p.targetPostId);
    }
}

