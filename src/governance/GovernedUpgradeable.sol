// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

abstract contract GovernedUpgradeable is Initializable, UUPSUpgradeable {
    address public governance;

    error NotGovernance();
    error ZeroAddress();

    event GovernanceSet(address indexed governance);

    function __GovernedUpgradeable_init(address governance_) internal onlyInitializing {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
        emit GovernanceSet(governance_);
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert NotGovernance();
        _;
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // 🔒 CRITICAL: lock implementation
    constructor() {
        _disableInitializers();
    }

    uint256[49] private __gap;
}

