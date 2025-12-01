// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakeEngine {
    struct StakeLot {
        address staker;
        uint256 amount;
        uint8 side; // 0 = support, 1 = challenge
        uint256 entryTimestamp; // unix timestamp of deposit
    }

    /// @notice Stake VSP on a post, on either support or challenge side.
    /// @param postId The target post id.
    /// @param side   0 = support, 1 = challenge.
    /// @param amount Amount of VSP to stake (must be non-zero).
    function stake(uint256 postId, uint8 side, uint256 amount) external;

    /// @notice Withdraw stake from a post using FIFO or LIFO selection.
    /// @dev This walks the caller's StakeLots on the chosen side, in FIFO or
    ///      LIFO order, until the requested amount is reached.
    /// @param postId   The target post id.
    /// @param side     0 = support, 1 = challenge.
    /// @param amount   Total amount to withdraw across lots.
    /// @param useLifo  If true, withdraw from latest lots first; otherwise
    ///                 withdraw from earliest lots first.
    function withdraw(uint256 postId, uint8 side, uint256 amount, bool useLifo) external;

    /// @notice View all stake lots on a given side of a post.
    /// @dev Ordering reflects arrival time (index 0 = earliest stake).
    function getStakeLots(uint256 postId, uint8 side) external view returns (StakeLot[] memory);

    /// @notice Optional view: total stake per side (for off-chain VS or analytics).
    function getTotals(uint256 postId) external view returns (uint256 supportTotal, uint256 challengeTotal);

    // Events

    event StakeAdded(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);

    event StakeWithdrawn(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);

    // Errors

    error InvalidSide();
    error AmountZero();
    error NotStaker();
    error InsufficientStake();
}

