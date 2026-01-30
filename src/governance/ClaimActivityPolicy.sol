// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IClaimActivityPolicy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract ClaimActivityPolicy is IClaimActivityPolicy {
    TimelockController public immutable timelock;

    uint256 public minTotalStakeVSP;

    event PolicyUpdated(uint256 oldValue, uint256 newValue);

    constructor(address timelock_, uint256 initialMinStake) {
        timelock = TimelockController(payable(timelock_));
        minTotalStakeVSP = initialMinStake;
        emit PolicyUpdated(0, initialMinStake);
    }

    function isActive(uint256 totalStake) external view override returns (bool) {
        return totalStake >= minTotalStakeVSP;
    }

    function setMinTotalStake(uint256 newValue) external {
        require(msg.sender == address(timelock), "not timelock");
        uint256 old = minTotalStakeVSP;
        minTotalStakeVSP = newValue;
        emit PolicyUpdated(old, newValue);
    }
}

