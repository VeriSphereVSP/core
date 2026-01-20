// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Read-only posting fee policy
/// @dev MUST remain stable forever
interface IPostingFeePolicy {
    /// @return Posting fee denominated in VSP wei
    function postingFeeVSP() external view returns (uint256);
}

