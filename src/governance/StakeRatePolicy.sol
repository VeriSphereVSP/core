// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title StakeRatePolicy
/// @notice Governs staking interest rate bounds (annualized)
contract StakeRatePolicy {
    TimelockController public immutable timelock;

    /// @dev Annualized rates in ray (1e18 = 100%)
    uint256 public stakeIntRateMinRay;
    uint256 public stakeIntRateMaxRay;

    event RatesUpdated(
        uint256 oldMin,
        uint256 oldMax,
        uint256 newMin,
        uint256 newMax
    );

    constructor(
        address timelock_,
        uint256 initialMinRay,
        uint256 initialMaxRay
    ) {
        timelock = TimelockController(payable(timelock_));
        stakeIntRateMinRay = initialMinRay;
        stakeIntRateMaxRay = initialMaxRay;

        emit RatesUpdated(0, 0, initialMinRay, initialMaxRay);
    }

    function setRates(uint256 newMinRay, uint256 newMaxRay) external {
        require(msg.sender == address(timelock), "not timelock");
        require(newMinRay <= newMaxRay, "min > max");

        emit RatesUpdated(
            stakeIntRateMinRay,
            stakeIntRateMaxRay,
            newMinRay,
            newMaxRay
        );

        stakeIntRateMinRay = newMinRay;
        stakeIntRateMaxRay = newMaxRay;
    }
}

