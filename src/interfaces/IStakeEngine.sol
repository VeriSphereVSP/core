// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IStakeEngine
/// @notice Interface for the StakeEngine contract used by other protocol components.
/// @dev Mirrors the public/external surface of StakeEngine.sol that is intended
///      to be used cross-contract or cross-repo.
interface IStakeEngine {
    // ------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------

    function SIDE_SUPPORT() external view returns (uint8);
    function SIDE_CHALLENGE() external view returns (uint8);

    // ------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------

    struct StakeLot {
        address staker;
        uint256 amount;
        uint8 side;        // 0 = support, 1 = challenge
        uint256 begin;     // queue-position start
        uint256 end;       // queue-position end
        uint256 mid;       // (begin + end) / 2
        uint256 entryEpoch;
    }

    // ------------------------------------------------------------------------
    // Core API
    // ------------------------------------------------------------------------

    /// @notice Stake VSP on a post, on either support or challenge side.
    /// @param postId The claim / post identifier.
    /// @param side SIDE_SUPPORT (0) or SIDE_CHALLENGE (1).
    /// @param amount Amount of VSP to stake.
    function stake(uint256 postId, uint8 side, uint256 amount) external;

    /// @notice Withdraw stake from a post, picking FIFO or LIFO across caller's lots.
    /// @param postId The claim / post identifier.
    /// @param side SIDE_SUPPORT (0) or SIDE_CHALLENGE (1).
    /// @param amount Amount of VSP to withdraw.
    /// @param lifo If true, withdraw from the newest lots first; otherwise from the oldest lots.
    function withdraw(uint256 postId, uint8 side, uint256 amount, bool lifo) external;

    /// @notice Apply growth/decay for all lots on a post based on elapsed epochs.
    /// @dev Anyone may call; typically a keeper or backend.
    /// @param postId The claim / post identifier.
    function updatePost(uint256 postId) external;

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice Get total support and challenge stake on a post.
    /// @param postId The post identifier.
    /// @return supportTotal Total support-side stake on the post.
    /// @return challengeTotal Total challenge-side stake on the post.
    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 supportTotal, uint256 challengeTotal);

    /// @notice Get the stake lots for a given post and side.
    /// @param postId The post identifier.
    /// @param side SIDE_SUPPORT (0) or SIDE_CHALLENGE (1).
    /// @return An array of StakeLots representing the queue on that side.
    function getLots(uint256 postId, uint8 side)
        external
        view
        returns (StakeLot[] memory);
}
