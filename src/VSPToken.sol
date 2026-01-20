// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./authority/Authority.sol";
import "./interfaces/IVSPToken.sol";

contract VSPToken is ERC20, IVSPToken {
    Authority public immutable authority;

    constructor(address authority_)
        ERC20("VeriSphere", "VSP")
    {
        authority = Authority(authority_);
    }

    modifier onlyMinter() {
        require(authority.isMinter(msg.sender), "not minter");
        _;
    }

    modifier onlyBurner() {
        require(authority.isBurner(msg.sender), "not burner");
        _;
    }

    // ------------------------------------------------------------
    // Mint / Burn (protocol authority)
    // ------------------------------------------------------------

    function mint(address to, uint256 amount)
        external
        onlyMinter
    {
        _mint(to, amount);
    }

    function burn(uint256 amount)
        external
        onlyBurner
    {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount)
        external
        onlyBurner
    {
        _burn(from, amount);
    }
}

