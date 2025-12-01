// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

interface IVSPToken is IERC20 {
    // Extra privileged functions for VSP

    function mint(address to, uint256 amount) external;

    function burn(uint256 amount) external;

    function burnFrom(address from, uint256 amount) external;
}

