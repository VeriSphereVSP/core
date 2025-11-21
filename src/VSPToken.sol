// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVSPToken} from "./interfaces/IVSPToken.sol";
import {Authority} from "./authority/Authority.sol";
import {IdleDecay} from "./staking/IdleDecay.sol";

contract VSPToken is ERC20, IVSPToken, IdleDecay {
    Authority public authority;

    constructor(address owner_)
        ERC20("VeriSphere Token", "VSP")
    {
        // Just set up the Authority; do NOT call owner-only methods here.
        authority = new Authority(owner_);
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
        uint256 decayed = _applyDecay(to);
        if (decayed > 0) {
            _beforeTokenBurn(to, decayed);
            super._burn(to, decayed);
        }

        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyBurner {
        address user = msg.sender;

        uint256 decayed = _applyDecay(user);
        if (decayed > 0) {
            _beforeTokenBurn(user, decayed);
            super._burn(user, decayed);
        }

        _beforeTokenBurn(user, amount);
        super._burn(user, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyBurner {
        uint256 decayed = _applyDecay(from);
        if (decayed > 0) {
            _beforeTokenBurn(from, decayed);
            super._burn(from, decayed);
        }

        _spendAllowance(from, msg.sender, amount);
        _beforeTokenBurn(from, amount);
        super._burn(from, amount);
    }

    // ---- Idle Decay ----

    function applyIdleDecay(address user)
        external
        onlyBurner
        returns (uint256)
    {
        uint256 decayed = _applyDecay(user);
        if (decayed > 0) {
            _beforeTokenBurn(user, decayed);
            super._burn(user, decayed);
        }
        return decayed;
    }

    function setIdleDecayRate(uint256 rateBps_) external onlyBurner {
        require(rateBps_ <= 2000, "max 20%");
        idleDecayRateBps = rateBps_;
    }

    function _balanceOf(address user)
        internal
        view
        override
        returns (uint256)
    {
        return balanceOf(user);
    }
}

