// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../interfaces/IProtocolPolicy.sol";

/// @title ProtocolPolicy
/// @notice Bundled governance policy. Single source of truth replacing
///         the former three policy contracts.
/// @dev    All setters require msg.sender == timelock and enforce hard
///         caps that even a fully-captured Timelock cannot exceed.
contract ProtocolPolicy is IProtocolPolicy {
    TimelockController public immutable timelock;

    uint256 public override stakeIntRateMinRay;
    uint256 public override stakeIntRateMaxRay;
    uint256 private _postingFeeVSP;
    uint256 public override minTotalStakeVSP;

    uint256 public constant MAX_RATE_MIN_RAY = 1e18;
    uint256 public constant MAX_RATE_MAX_RAY = 5e18;
    uint256 public constant MIN_POSTING_FEE_WEI = 1e15;
    uint256 public constant MAX_POSTING_FEE_WEI = 100e18;
    uint256 public constant MAX_MIN_STAKE_WEI = 10000e18;

    error NotTimelock();
    error RateOutOfBounds();
    error FeeOutOfBounds();
    error MinStakeOutOfBounds();

    event RatesUpdated(uint256 oldMin, uint256 oldMax, uint256 newMin, uint256 newMax);
    event PostingFeeUpdated(uint256 oldFee, uint256 newFee);
    event MinTotalStakeUpdated(uint256 oldValue, uint256 newValue);

    modifier onlyTimelock() {
        if (msg.sender != address(timelock)) {
            revert NotTimelock();
        }
        _;
    }

    constructor(
        address timelock_,
        uint256 initialRateMinRay,
        uint256 initialRateMaxRay,
        uint256 initialPostingFee,
        uint256 initialMinTotalStake
    ) {
        if (initialRateMinRay > MAX_RATE_MIN_RAY) {
            revert RateOutOfBounds();
        }
        if (initialRateMaxRay > MAX_RATE_MAX_RAY) {
            revert RateOutOfBounds();
        }
        if (initialRateMinRay > initialRateMaxRay) {
            revert RateOutOfBounds();
        }
        if (initialPostingFee < MIN_POSTING_FEE_WEI || initialPostingFee > MAX_POSTING_FEE_WEI) {
            revert FeeOutOfBounds();
        }
        if (initialMinTotalStake > MAX_MIN_STAKE_WEI) {
            revert MinStakeOutOfBounds();
        }

        timelock = TimelockController(payable(timelock_));
        stakeIntRateMinRay = initialRateMinRay;
        stakeIntRateMaxRay = initialRateMaxRay;
        _postingFeeVSP = initialPostingFee;
        minTotalStakeVSP = initialMinTotalStake;

        emit RatesUpdated(0, 0, initialRateMinRay, initialRateMaxRay);
        emit PostingFeeUpdated(0, initialPostingFee);
        emit MinTotalStakeUpdated(0, initialMinTotalStake);
    }

    function postingFeeVSP() external view override returns (uint256) {
        return _postingFeeVSP;
    }

    function isActive(uint256 totalStake) external view override returns (bool) {
        return totalStake >= minTotalStakeVSP;
    }

    function setRates(uint256 newMinRay, uint256 newMaxRay) external onlyTimelock {
        if (newMinRay > MAX_RATE_MIN_RAY) {
            revert RateOutOfBounds();
        }
        if (newMaxRay > MAX_RATE_MAX_RAY) {
            revert RateOutOfBounds();
        }
        if (newMinRay > newMaxRay) {
            revert RateOutOfBounds();
        }
        emit RatesUpdated(stakeIntRateMinRay, stakeIntRateMaxRay, newMinRay, newMaxRay);
        stakeIntRateMinRay = newMinRay;
        stakeIntRateMaxRay = newMaxRay;
    }

    function setPostingFee(uint256 newFee) external onlyTimelock {
        if (newFee < MIN_POSTING_FEE_WEI || newFee > MAX_POSTING_FEE_WEI) {
            revert FeeOutOfBounds();
        }
        uint256 old = _postingFeeVSP;
        _postingFeeVSP = newFee;
        emit PostingFeeUpdated(old, newFee);
    }

    function setMinTotalStake(uint256 newValue) external onlyTimelock {
        if (newValue > MAX_MIN_STAKE_WEI) {
            revert MinStakeOutOfBounds();
        }
        uint256 old = minTotalStakeVSP;
        minTotalStakeVSP = newValue;
        emit MinTotalStakeUpdated(old, newValue);
    }
}
