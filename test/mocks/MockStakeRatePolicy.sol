// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal stake-rate policy for tests.
///         Matches StakeRatePolicy interface used by StakeEngine.
contract MockStakeRatePolicy {
    /// @dev 0 = no minimum rate
    function stakeIntRateMinRay() external pure returns (uint256) {
        return 0;
    }

    /// @dev 50e16 = 50% annual max rate (matches deploy script default)
    function stakeIntRateMaxRay() external pure returns (uint256) {
        return 50e16;
    }
}
