// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IVSPToken.sol";
import "./authority/Authority.sol";

/// @title VSPToken
/// @notice ERC20 token with controlled mint/burn for VeriSphere
contract VSPToken is ERC20, IVSPToken {
    Authority public immutable authority;

    constructor(address authority_) ERC20("VeriSphere", "VSP") {
        authority = Authority(authority_);
    }

    // -----------------------------
    // Mint / Burn (protocol hooks)
    // -----------------------------

    function mint(address to, uint256 amount) external override {
        require(authority.isMinter(msg.sender), "VSP: not minter");
        _mint(to, amount);
    }

    function burn(uint256 amount) external override {
        require(authority.isBurner(msg.sender), "VSP: not burner");
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external override {
        require(authority.isBurner(msg.sender), "VSP: not burner");
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}

