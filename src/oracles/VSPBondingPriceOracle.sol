// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "../interfaces/IGoldPriceOracle.sol";
import "../interfaces/IVSPPriceOracle.sol";

contract VSPBondingPriceOracle is IVSPPriceOracle {
    uint256 constant RAY = 1e18;

    address public owner;
    IGoldPriceOracle public gold;

    uint256 public auOzPerVSPAtLaunchRay;
    uint256 public nNetVSPSoldWhole;

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    constructor(
        address owner_,
        address goldOracle_,
        uint256 launchPegRay_
    ) {
        owner = owner_;
        gold = IGoldPriceOracle(goldOracle_);
        auOzPerVSPAtLaunchRay = launchPegRay_;
    }

    function setNetVSPSoldWhole(uint256 n) external onlyOwner {
        nNetVSPSoldWhole = n;
    }

    function usdPerVSPRay() external view override returns (uint256) {
        uint256 g = gold.usdPerTroyOzRay();
        uint256 m = _log10FloorRay(nNetVSPSoldWhole + 10);
        if (m == 0) m = RAY;

        uint256 baseUsd = Math.mulDiv(
            auOzPerVSPAtLaunchRay,
            g,
            RAY
        );

        return Math.mulDiv(baseUsd, m, RAY);
    }

    function _log10FloorRay(uint256 x) internal pure returns (uint256) {
        uint256 k;
        while (x >= 10) {
            x /= 10;
            k++;
        }
        return k * RAY;
    }
}

