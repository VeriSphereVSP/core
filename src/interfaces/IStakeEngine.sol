// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStakeEngine
/// @notice Interface for the staking engine used by ScoreEngine and views.
/// @dev Only the cross-contract surface is exposed here.
interface IStakeEngine {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    function SIDE_SUPPORT() external pure returns (uint8);
    function SIDE_CHALLENGE() external pure returns (uint8);

    // ---------------------------------------------------------------------
    // Core staking actions
    // ---------------------------------------------------------------------

    function stake(uint256 postId, uint8 side, uint256 amount) external;

    function withdraw(
        uint256 postId,
        uint8 side,
        uint256 amount,
        bool lifo
    ) external;

    function updatePost(uint256 postId) external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 support, uint256 challenge);

    /// @notice Minimum total stake required for a post to be economically active
    function postingFeeThreshold() external view returns (uint256);
}

