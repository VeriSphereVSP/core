// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IAggregatorV3.sol";
import "../interfaces/IGoldPriceOracle.sol";

/// @title ChainlinkGoldOracle
/// @notice Oracle returning the USD price of one troy ounce of gold (XAU)
/// @dev Uses a Chainlink-style AggregatorV3 feed injected at deploy time.
///      No dependency on Chainlink repo — interface is locally defined.
contract ChainlinkGoldOracle is IGoldPriceOracle {
    /// @notice Chainlink XAU / USD price feed
    IAggregatorV3 public immutable feed;

    /// @param feed_ Address of a Chainlink-compatible XAU/USD aggregator
    constructor(address feed_) {
        require(feed_ != address(0), "gold oracle: zero feed");
        feed = IAggregatorV3(feed_);
    }

    /// @notice Returns USD per troy ounce of gold, ray-scaled (1e18)
    /// @dev Most Chainlink XAU/USD feeds use 8 decimals
    function usdPerTroyOzRay() external view override returns (uint256) {
        (
            ,
            int256 answer,
            ,
            uint256 updatedAt,
            
        ) = feed.latestRoundData();

        require(answer > 0, "gold oracle: invalid price");
        require(updatedAt != 0, "gold oracle: stale round");

        // Convert 8-decimal USD price → ray (1e18)
        // Example: 2000.12345678 USD → 2000123456780000000000
        return uint256(answer) * 1e10;
    }
}

