// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../interfaces/IPostingFeePolicy.sol";

contract PostingFeePolicy is IPostingFeePolicy {
    TimelockController public immutable timelock;
    uint256 private _postingFeeVSP;

    event PostingFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(address timelock_, uint256 initialFee) {
        timelock = TimelockController(payable(timelock_)); // Cast to payable
        _postingFeeVSP = initialFee;
        emit PostingFeeUpdated(0, initialFee);
    }

    function postingFeeVSP() external view override returns (uint256) {
        return _postingFeeVSP;
    }

    function setPostingFee(uint256 newFee) external {
        require(msg.sender == address(timelock), "not timelock");
        uint256 old = _postingFeeVSP;
        _postingFeeVSP = newFee;
        emit PostingFeeUpdated(old, newFee);
    }
}
