// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IVSPToken} from "./interfaces/IVSPToken.sol";
import {IStakeEngine} from "./interfaces/IStakeEngine.sol";

/// @title StakeEngine
/// @notice Minimal staking ledger for VeriSphere. Economic logic (yields, burns)
///         is applied off-chain or in a separate module using the data recorded here.
contract StakeEngine is IStakeEngine {
    IVSPToken public immutable vspToken;

    // postId => side (0 support, 1 challenge) => array of stake lots
    mapping(uint256 => mapping(uint8 => StakeLot[])) internal _stakeLots;

    // postId => total support / challenge stake
    mapping(uint256 => uint256) internal _supportTotal;
    mapping(uint256 => uint256) internal _challengeTotal;

    constructor(address _vspToken) {
        require(_vspToken != address(0), "StakeEngine: zero VSP");
        vspToken = IVSPToken(_vspToken);
    }

    /// @inheritdoc IStakeEngine
    function stake(uint256 postId, uint8 side, uint256 amount) external override {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        // Pull VSP from user. User must have approved this contract.
        vspToken.transferFrom(msg.sender, address(this), amount);

        StakeLot memory lot =
            StakeLot({staker: msg.sender, amount: amount, side: side, entryTimestamp: block.timestamp});

        _stakeLots[postId][side].push(lot);

        if (side == 0) {
            _supportTotal[postId] += amount;
        } else {
            _challengeTotal[postId] += amount;
        }

        emit StakeAdded(postId, msg.sender, side, amount);
    }

    /// @inheritdoc IStakeEngine
    function withdraw(uint256 postId, uint8 side, uint256 amount, bool useLifo) external override {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        StakeLot[] storage lots = _stakeLots[postId][side];
        uint256 remaining = amount;
        uint256 totalWithdrawn = 0;

        if (!useLifo) {
            // FIFO: earliest lots first (index 0 upward)
            uint256 len = lots.length;
            for (uint256 i = 0; i < len && remaining > 0; i++) {
                StakeLot storage lot = lots[i];
                if (lot.staker != msg.sender || lot.amount == 0) {
                    continue;
                }
                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining -= take;
                totalWithdrawn += take;
            }
        } else {
            // LIFO: latest lots first (last index downward)
            int256 i = int256(lots.length) - 1;
            while (i >= 0 && remaining > 0) {
                StakeLot storage lot = lots[uint256(i)];
                if (lot.staker == msg.sender && lot.amount > 0) {
                    uint256 take = lot.amount < remaining ? lot.amount : remaining;
                    lot.amount -= take;
                    remaining -= take;
                    totalWithdrawn += take;
                }
                unchecked {
                    i--;
                }
            }
        }

        if (totalWithdrawn == 0 || remaining > 0) {
            // Nothing or not enough could be withdrawn for this user.
            revert InsufficientStake();
        }

        if (side == 0) {
            _supportTotal[postId] -= totalWithdrawn;
        } else {
            _challengeTotal[postId] -= totalWithdrawn;
        }

        // Send tokens back to user.
        vspToken.transfer(msg.sender, totalWithdrawn);

        emit StakeWithdrawn(postId, msg.sender, side, totalWithdrawn);
    }

    /// @inheritdoc IStakeEngine
    function getStakeLots(uint256 postId, uint8 side) external view override returns (StakeLot[] memory) {
        return _stakeLots[postId][side];
    }

    /// @inheritdoc IStakeEngine
    function getTotals(uint256 postId) external view override returns (uint256 supportTotal, uint256 challengeTotal) {
        supportTotal = _supportTotal[postId];
        challengeTotal = _challengeTotal[postId];
    }
}

