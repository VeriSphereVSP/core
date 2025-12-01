// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
    PostRegistry
    ------------
    Minimal on-chain registry for VeriSphere atomic claims ("posts").

    Responsibilities:
    - Store immutable posts (creator, timestamp, text)
    - Track support and challenge stake totals (updated by StakeEngine)
    - No staking logic here (handled in StakeEngine)
    - No verity score calculation (performed off-chain or in a helper)
*/

contract PostRegistry {
    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event PostCreated(uint256 indexed postId, address indexed creator, string text);

    event StakeTotalsUpdated(uint256 indexed postId, uint256 supportTotal, uint256 challengeTotal);

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
        uint256 supportTotal;
        uint256 challengeTotal;
    }

    uint256 public nextPostId = 1;

    // postId => Post
    mapping(uint256 => Post) internal posts;

    // StakeEngine address allowed to update totals
    address public stakeEngine;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyStakeEngine() {
        if (msg.sender != stakeEngine) revert NotStakeEngine();
        _;
    }

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    constructor() {
        // stakeEngine must be set later by owner/governance
    }

    // Can be wired by governance contract, owner, or Authority later
    function setStakeEngine(address engine) external {
        // NOTE: use Authority in production repo
        // This MVP version keeps it open.
        stakeEngine = engine;
    }

    // ---------------------------------------------------------------------
    // Post Creation
    // ---------------------------------------------------------------------

    function createPost(string calldata text) external returns (uint256 postId) {
        if (bytes(text).length == 0) {
            revert EmptyText();
        }

        postId = nextPostId;
        nextPostId += 1;

        posts[postId] =
            Post({creator: msg.sender, timestamp: block.timestamp, text: text, supportTotal: 0, challengeTotal: 0});

        emit PostCreated(postId, msg.sender, text);
    }

    // ---------------------------------------------------------------------
    // View: Read a post
    // ---------------------------------------------------------------------

    function getPost(uint256 postId)
        external
        view
        returns (address creator, uint256 timestamp, string memory text, uint256 supportTotal, uint256 challengeTotal)
    {
        if (postId == 0 || postId >= nextPostId) revert InvalidPostId();
        Post storage p = posts[postId];
        return (p.creator, p.timestamp, p.text, p.supportTotal, p.challengeTotal);
    }

    // ---------------------------------------------------------------------
    // Mutation: Totals update (StakeEngine only)
    // ---------------------------------------------------------------------

    function updateStakeTotals(uint256 postId, uint256 newSupport, uint256 newChallenge) external onlyStakeEngine {
        if (postId == 0 || postId >= nextPostId) revert InvalidPostId();

        Post storage p = posts[postId];
        p.supportTotal = newSupport;
        p.challengeTotal = newChallenge;

        emit StakeTotalsUpdated(postId, newSupport, newChallenge);
    }
}

