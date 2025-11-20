// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IVSPToken} from "./interfaces/IVSPToken.sol";
import {Authority} from "./authority/Authority.sol";
import {IdleDecay} from "./staking/IdleDecay.sol";

contract VSPToken is ERC20, IVSPToken, IdleDecay {
    Authority public authority;

    constructor(address owner)
        ERC20("VeriSphere Token", "VSP")
    {
        authority = new Authority(owner);
        authority.setMinter(owner, true);
        authority.setBurner(owner, true);
    }

    modifier onlyMinter() {
        require(authority.isMinter(msg.sender), "VSP: not minter");
        _;
    }

    modifier onlyBurner() {
        require(authority.isBurner(msg.sender), "VSP: not burner");
        _;
    }

    // ---- Mint & Burn ----

    function mint(address to, uint256 amount) external onlyMinter {
        _applyDecay(to);
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyBurner {
        _applyDecay(msg.sender);
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyBurner {
        _applyDecay(from);
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }

    // ---- Idle Decay ----

    function applyIdleDecay(address user)
        external
        onlyBurner
        returns (uint256)
    {
        return _applyDecay(user);
    }

    function setIdleDecayRate(uint256 rateBps_) external onlyBurner {
        require(rateBps_ <= 2000, "max 20%");
        idleDecayRateBps = rateBps_;
    }

    function _burn(address from, uint256 amount) internal override(IdleDecay, ERC20) {
        super._burn(from, amount);
    }

    function _balanceOf(address user) internal view override returns (uint256) {
        return balanceOf(user);
    }
}

