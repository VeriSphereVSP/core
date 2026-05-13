// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IProtocolPolicy
/// @notice Read-only interface for the bundled governance policy.
/// @dev    All consumers (StakeEngine, PostRegistry, ScoreEngine,
///         ProtocolViews) reference this single interface. Concrete
///         implementation: ProtocolPolicy in governance/ProtocolPolicy.sol.
///         Per THREAT-MODEL.md §2.5, all governance-tunable parameters
///         have hard caps in code that cannot be exceeded by governance.
interface IProtocolPolicy {
    function stakeIntRateMinRay() external view returns (uint256);
    function stakeIntRateMaxRay() external view returns (uint256);
    function postingFeeVSP() external view returns (uint256);
    function isActive(uint256 totalStake) external view returns (bool);
    function minTotalStakeVSP() external view returns (uint256);
}
