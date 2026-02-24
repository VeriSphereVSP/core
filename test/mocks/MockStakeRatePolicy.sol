// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal stake-rate policy for tests
contract MockStakeRatePolicy {
    function stakeInterestRateAnnualMin() external pure returns (uint256) {
        return 0;
    }

    function stakeInterestRateAnnualMax() external pure returns (uint256) {
        return 1;
    }

    function yearLengthSeconds() external pure returns (uint256) {
        return 365 days;
    }
}

