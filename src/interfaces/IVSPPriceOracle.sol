// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVSPPriceOracle {
    /// USD per VSP, 1e18
    function usdPerVSPRay() external view returns (uint256);
}

