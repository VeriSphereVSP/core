// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStakeEngine
/// @notice Interface for the staking engine used by ScoreEngine and views.
/// @dev Only the cross-contract surface is exposed here. Richer views
///      (like per-lot introspection) are available on StakeEngine itself.
interface IStakeEngine {
    /// @dev Side constants for support / challenge.
    function SIDE_SUPPORT() external pure returns (uint8);
    function SIDE_CHALLENGE() external pure returns (uint8);

    /// @notice Stake `amount` of VSP on `postId` and `side`.
    /// @param postId Claim or link post id.
    /// @param side   SIDE_SUPPORT or SIDE_CHALLENGE.
    /// @param amount Amount of VSP to lock.
    function stake(uint256 postId, uint8 side, uint256 amount) external;

    /// @notice Withdraw `amount` of stake from `postId` and `side`.
    /// @param lifo Whether to withdraw from the newest lots first.
    function withdraw(uint256 postId, uint8 side, uint256 amount, bool lifo) external;

    /// @notice Update a post's epoch state (compounding gains / losses).
    function updatePost(uint256 postId) external;

    /// @notice Get the total support / challenge stake for a post.
    /// @return support  Total support-side stake.
    /// @return challenge Total challenge-side stake.
    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 support, uint256 challenge);
}

