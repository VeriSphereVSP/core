// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockClaimActivityPolicy
/// @notice Minimal test-only mock for ClaimActivityPolicy
/// @dev Treats any post with totalStake > 0 as active
contract MockClaimActivityPolicy {
    function isActive(uint256 totalStake) external pure returns (bool) {
        return totalStake > 0;
    }
}

