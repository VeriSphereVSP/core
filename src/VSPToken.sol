// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./authority/Authority.sol";
import "./interfaces/IVSPToken.sol";

/// @title VSPToken — VeriSphere ERC-20 with permit and UUPS upgradeability
/// @notice Mint/burn gated by Authority roles. ERC-2612 permit for gasless approvals.
contract VSPToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    UUPSUpgradeable,
    IVSPToken
{
    Authority public authority;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address authority_) external initializer {
        __ERC20_init("VeriSphere", "VSP");
        __ERC20Permit_init("VeriSphere");
        authority = Authority(authority_);
    }

    // ── Access control ──────────────────────────────────────

    modifier onlyMinter() {
        require(authority.isMinter(msg.sender), "not minter");
        _;
    }

    modifier onlyBurner() {
        require(authority.isBurner(msg.sender), "not burner");
        _;
    }

    modifier onlyGovernance() {
        require(authority.owner() == msg.sender, "not governance");
        _;
    }

    // ── Mint / Burn (protocol authority) ────────────────────

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyBurner {
        _burn(msg.sender, amount);
    }

    /// @notice Burns tokens from `from`, requiring ERC-20 allowance.
    /// @dev Caller must have the burner role AND sufficient allowance from `from`.
    function burnFrom(address from, uint256 amount) external onlyBurner {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    // ── UUPS upgrade authorization ──────────────────────────

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyGovernance {}
}
