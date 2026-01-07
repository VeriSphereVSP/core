// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Oracle interface returning gold price
interface IGoldPriceOracle {
    /// @return usdPerOzRay USD per troy ounce of gold, scaled by 1e18
    function usdPerTroyOzRay() external view returns (uint256);
}

