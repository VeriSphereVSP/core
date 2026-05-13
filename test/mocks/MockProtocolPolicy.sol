// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IProtocolPolicy.sol";

/// @title MockProtocolPolicy
/// @notice Single test mock replacing the pre-Patch-17 trio
///         (MockPostingFeePolicy, MockStakeRatePolicy, MockClaimActivityPolicy).
///         Defaults match the old per-mock defaults: rate max 50% APR,
///         no min stake threshold, no rate min. Posting fee is the
///         single constructor argument.
contract MockProtocolPolicy is IProtocolPolicy {
    uint256 public override stakeIntRateMinRay;
    uint256 public override stakeIntRateMaxRay;
    uint256 private _postingFeeVSP;
    uint256 public override minTotalStakeVSP;

    /// @param fee Posting fee in VSP wei. Other parameters default to
    ///        sensible test values (matches pre-Patch-17 behavior).
    constructor(uint256 fee) {
        _postingFeeVSP = fee;
        stakeIntRateMinRay = 0;
        stakeIntRateMaxRay = 50e16;   // 50% APR — matches old MockStakeRatePolicy
        minTotalStakeVSP = 0;          // matches old MockClaimActivityPolicy (any > 0 is active)
    }

    function postingFeeVSP() external view override returns (uint256) {
        return _postingFeeVSP;
    }

    function isActive(uint256 totalStake) external view override returns (bool) {
        // Match old MockClaimActivityPolicy semantics when threshold is 0:
        // "active if > 0". With a configured threshold, use it.
        if (minTotalStakeVSP == 0) return totalStake > 0;
        return totalStake >= minTotalStakeVSP;
    }

    // ── Test-only setters (NO access control — test-mock only) ───────
    function setPostingFee(uint256 f) external { _postingFeeVSP = f; }
    function setRates(uint256 minR, uint256 maxR) external {
        stakeIntRateMinRay = minR;
        stakeIntRateMaxRay = maxR;
    }
    function setMinTotalStake(uint256 v) external { minTotalStakeVSP = v; }
}
