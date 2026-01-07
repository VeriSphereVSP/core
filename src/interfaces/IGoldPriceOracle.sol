// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IGoldPriceOracle {
    /// USD per troy ounce, 1e18
    function usdPerTroyOzRay() external view returns (uint256);
}

