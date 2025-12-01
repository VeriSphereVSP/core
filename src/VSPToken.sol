// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IVSPToken} from "./interfaces/IVSPToken.sol";
import {Authority} from "./authority/Authority.sol";

contract VSPToken is ERC20, IVSPToken {
    Authority public authority;

    constructor(address owner) ERC20("VeriSphere Token", "VSP") {
        authority = new Authority(owner);
    }

    modifier onlyMinter() {
        require(authority.isMinter(msg.sender), "VSP: not minter");
        _;
    }

    modifier onlyBurner() {
        require(authority.isBurner(msg.sender), "VSP: not burner");
        _;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        _mint(to, amount);
    }

    function burn(uint256 amount) external onlyBurner {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyBurner {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}

