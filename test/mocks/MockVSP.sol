// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IVSPToken.sol";

contract MockVSP is IVSPToken {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public totalSupplyStored;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupplyStored += amount;
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyStored;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "insufficient balance");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "insufficient allowance");
        require(balances[from] >= amount, "insufficient balance");

        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        require(balances[msg.sender] >= amount, "insufficient balance");
        balances[msg.sender] -= amount;
        totalSupplyStored -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        // Enforce allowance (this is what was missing!)
        require(allowances[from][msg.sender] >= amount, "insufficient allowance");
        require(balances[from] >= amount, "insufficient balance");

        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        totalSupplyStored -= amount;
    }
}
