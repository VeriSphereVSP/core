// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/metatx/ERC2771ContextUpgradeable.sol";
import "./authority/Authority.sol";
import "./interfaces/IVSPToken.sol";

/// @title VSPToken — VeriSphere ERC-20 with permit, ERC-2771, and UUPS upgradeability
contract VSPToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable,
    ERC2771ContextUpgradeable,
    IVSPToken
{
    Authority public authority;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) ERC2771ContextUpgradeable(trustedForwarder_) {
        _disableInitializers();
    }

    function initialize(address authority_) external initializer {
        __ERC20_init("VeriSphere", "VSP");
        __ERC20Permit_init("VeriSphere");
        authority = Authority(authority_);
    }

    modifier onlyMinter() {
        require(authority.isMinter(_msgSender()), "not minter");
        _;
    }

    modifier onlyBurner() {
        require(authority.isBurner(_msgSender()), "not burner");
        _;
    }

    modifier onlyGovernance() {
        require(authority.owner() == _msgSender(), "not governance");
        _;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyBurner {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address from, uint256 amount) external onlyBurner {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }

    function _authorizeUpgrade(address) internal override onlyGovernance {}

    function _msgSender() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (address) {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (bytes calldata) {
        return ERC2771ContextUpgradeable._msgData();
    }

    function _contextSuffixLength() internal view override(ContextUpgradeable, ERC2771ContextUpgradeable) returns (uint256) {
        return ERC2771ContextUpgradeable._contextSuffixLength();
    }

    uint256[500] private __gap;
}
