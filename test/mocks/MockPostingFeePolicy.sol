// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../src/interfaces/IPostingFeePolicy.sol";

contract MockPostingFeePolicy is IPostingFeePolicy {
    uint256 public fee;

    constructor(uint256 f) {
        fee = f;
    }

    function postingFeeVSP() external view returns (uint256) {
        return fee;
    }
}

