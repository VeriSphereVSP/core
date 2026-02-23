// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";

/// @title GovernedUpgradeable
/// @notice Base contract for all upgradeable protocol contracts.
///         Provides UUPS upgrade authorization gated by governance,
///         and ERC-2771 trusted forwarder support so meta-transactions
///         resolve _msgSender() to the real end-user, not the relayer.
///
///         In OZ v5.5, ERC2771ContextUpgradeable stores the trusted forwarder
///         as an immutable set in the constructor (not via initializer).
///         With UUPS proxies this works because immutables are embedded in
///         the implementation bytecode that the proxy delegatecalls to.
abstract contract GovernedUpgradeable is
    Initializable,
    UUPSUpgradeable,
    ERC2771ContextUpgradeable
{
    address public governance;

    error NotGovernance();
    error ZeroAddress();

    event GovernanceSet(address indexed governance);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    function __GovernedUpgradeable_init(
        address governance_
    ) internal onlyInitializing {
        if (governance_ == address(0)) revert ZeroAddress();
        governance = governance_;
        emit GovernanceSet(governance_);
    }

    modifier onlyGovernance() {
        if (_msgSender() != governance) revert NotGovernance();
        _;
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    // ----- Solidity diamond override resolution -----

    function _msgSender()
        internal
        view
        virtual
        override
        returns (address)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength()
        internal
        view
        virtual
        override
        returns (uint256)
    {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    uint256[49] private __gap;
}
