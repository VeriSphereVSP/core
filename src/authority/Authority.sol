// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Authority {
    address public owner;
    mapping(address => bool) public isMinter;
    mapping(address => bool) public isBurner;

    event OwnerChanged(address indexed newOwner);
    event MinterSet(address indexed minter, bool allowed);
    event BurnerSet(address indexed burner, bool allowed);

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "AUTH: not owner");
        _;
    }

    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
        emit OwnerChanged(newOwner);
    }

    function setMinter(address who, bool allowed) external onlyOwner {
        isMinter[who] = allowed;
        emit MinterSet(who, allowed);
    }

    function setBurner(address who, bool allowed) external onlyOwner {
        isBurner[who] = allowed;
        emit BurnerSet(who, allowed);
    }
}

