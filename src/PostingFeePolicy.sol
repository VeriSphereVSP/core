// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PostingFeePolicy
/// @notice Governance-controlled posting fee (denominated in VSP)
contract PostingFeePolicy {
    uint256 public postingFee; // in raw VSP units

    event PostingFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(uint256 initialFee) {
        postingFee = initialFee;
    }

    function setPostingFee(uint256 newFee) external {
        uint256 old = postingFee;
        postingFee = newFee;
        emit PostingFeeUpdated(old, newFee);
    }
}

