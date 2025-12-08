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
    - targetPostId (0=standalone, >0 support, <0 challenge)
    - supportTotal / challengeTotal (updated by StakeEngine)

    This contract:
    - DOES create posts
    - DOES store link intent via targetPostId
    - DOES allow StakeEngine to update stake totals
    - DOES NOT implement verity score logic
    - DOES NOT enforce DAG rules on-chain (handled off-chain)
*/

contract PostRegistry {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PostCreated(
        uint256 indexed postId,
        address indexed creator,
        string text,
        int256 targetPostId
    );

    event StakeTotalsUpdated(
        uint256 indexed postId,
        uint256 supportTotal,
        uint256 challengeTotal
    );

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error EmptyText();
    error InvalidPostId();
    error NotStakeEngine();

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    struct Post {
        address creator;
        uint256 timestamp;
        string text;
        int256 targetPostId;          // 0=standalone, >0 support, <0 challenge
        uint256 supportTotal;
        uint256 challengeTotal;
    }

    uint256 public nextPostId = 1;

    // postId => Post
    mapping(uint256 => Post) internal posts;

    // Only the StakeEngine contract may update stake totals
    address public stakeEngine;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyStakeEngine() {
        if (msg.sender != stakeEngine) revert NotStakeEngine();
        _;
    }

    // ---------------------------------------------------------------------
    // Initialization / Wiring
    // ---------------------------------------------------------------------

    constructor() {
        // stakeEngine set later via setStakeEngine()
    }

    /// @notice Set the StakeEngine address.
    /// @dev In production this should require governance / Authority.
    function setStakeEngine(address engine) external {
        stakeEngine = engine;
    }

    // ---------------------------------------------------------------------
    // Post Creation
    // ---------------------------------------------------------------------

    /// @notice Create a new post or link.
    /// @param text The human-readable claim text.
    /// @param targetPostId:
    ///        0  → standalone post
    ///        >0 → support link to target
    ///        <0 → challenge link to abs(target)
    function createPost(string calldata text, int256 targetPostId)
        external
        returns (uint256 postId)
    {
        if (bytes(text).length == 0) revert EmptyText();

        postId = nextPostId;
        nextPostId++;

        posts[postId] = Post({
            creator: msg.sender,
            timestamp: block.timestamp,
            text: text,
            targetPostId: targetPostId,
            supportTotal: 0,
            challengeTotal: 0
        });

        emit PostCreated(postId, msg.sender, text, targetPostId);
    }

    // ---------------------------------------------------------------------
    // View Functions
    // ---------------------------------------------------------------------

    function getPost(uint256 postId)
        external
        view
        returns (
            address creator,
            uint256 timestamp,
            string memory text,
            int256 targetPostId,
            uint256 supportTotal,
            uint256 challengeTotal
        )
    {
        if (postId == 0 || postId >= nextPostId) revert InvalidPostId();

        Post storage p = posts[postId];

        return (
            p.creator,
            p.timestamp,
            p.text,
            p.targetPostId,
            p.supportTotal,
            p.challengeTotal
        );
    }

    // ---------------------------------------------------------------------
    // StakeEngine → PostRegistry
    // ---------------------------------------------------------------------

    /// @notice StakeEngine updates a post’s support/challenge totals.
    function updateStakeTotals(
        uint256 postId,
        uint256 newSupport,
        uint256 newChallenge
    )
        external
        onlyStakeEngine
    {
        if (postId == 0 || postId >= nextPostId) revert InvalidPostId();

        Post storage p = posts[postId];
        p.supportTotal = newSupport;
        p.challengeTotal = newChallenge;

        emit StakeTotalsUpdated(postId, newSupport, newChallenge);
    }
}

