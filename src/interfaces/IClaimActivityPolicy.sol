// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IClaimActivityPolicy {
    function isActive(uint256 totalStake) external view returns (bool);
}

