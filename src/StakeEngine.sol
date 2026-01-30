// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";
import "./governance/StakeRatePolicy.sol";
import "./governance/GovernedUpgradeable.sol";

contract StakeEngine is GovernedUpgradeable {
    uint8 public constant SIDE_SUPPORT = 0;
    uint8 public constant SIDE_CHALLENGE = 1;

    struct StakeLot {
        address staker;
        uint256 amount;
        uint8 side;
        uint256 begin;
        uint256 end;
        uint256 mid;
        uint256 entryEpoch;
    }

    struct SideQueue {
        StakeLot[] lots;
        uint256 total;
    }

    struct PostState {
        SideQueue[2] sides;
        uint256 lastUpdatedEpoch;
    }

    IERC20 public ERC20_TOKEN;
    IVSPToken public VSP_TOKEN;
    StakeRatePolicy public ratePolicy;

    mapping(uint256 => PostState) private posts;

    uint256 public sMax;
    uint256 public sMaxLastUpdatedEpoch;

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_LENGTH = 365 days;
    uint256 private constant RAY = 1e18;

    uint256 private constant SMAX_DECAY_RATE_RAY = 999e15;
    uint256 private constant SMAX_MAX_DECAY_EPOCHS = 3650;

    error InvalidSide();
    error AmountZero();
    error NotEnoughStake();
    error ZeroAddressToken();

    event StakeAdded(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);
    event StakeWithdrawn(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount, bool lifo);
    event PostUpdated(uint256 indexed postId, uint256 epoch, uint256 supportTotal, uint256 challengeTotal);
    event EpochMinted(uint256 indexed postId, uint256 amount);
    event EpochBurned(uint256 indexed postId, uint256 amount);

    function initialize(
        address governance_,
        address vspToken_,
        address ratePolicy_
    ) external initializer {
        if (vspToken_ == address(0)) revert ZeroAddressToken();

        __GovernedUpgradeable_init(governance_);

        ERC20_TOKEN = IERC20(vspToken_);
        VSP_TOKEN = IVSPToken(vspToken_);
        ratePolicy = StakeRatePolicy(ratePolicy_);

        sMaxLastUpdatedEpoch = _currentEpoch();
    }

    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 support, uint256 challenge)
    {
        PostState storage ps = posts[postId];
        return (ps.sides[0].total, ps.sides[1].total);
    }

    function stake(uint256 postId, uint8 side, uint256 amount) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        ERC20_TOKEN.transferFrom(msg.sender, address(this), amount);

        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        if (ps.lastUpdatedEpoch == 0) ps.lastUpdatedEpoch = epoch;

        _addLot(postId, side, amount, msg.sender);
        emit StakeAdded(postId, msg.sender, side, amount);
    }

    function withdraw(uint256 postId, uint8 side, uint256 amount, bool lifo) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        SideQueue storage q = posts[postId].sides[side];

        uint256 remaining = amount;
        uint256 len = q.lots.length;
        if (len == 0) revert NotEnoughStake();

        if (lifo) {
            for (uint256 i = len; i > 0 && remaining > 0; i--) {
                StakeLot storage lot = q.lots[i - 1];
                if (lot.staker != msg.sender || lot.amount == 0) continue;
                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining -= take;
            }
        } else {
            for (uint256 i = 0; i < len && remaining > 0; i++) {
                StakeLot storage lot = q.lots[i];
                if (lot.staker != msg.sender || lot.amount == 0) continue;
                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining -= take;
            }
        }

        if (remaining > 0) revert NotEnoughStake();

        _recomputePostTotals(postId);
        ERC20_TOKEN.transfer(msg.sender, amount);

        emit StakeWithdrawn(postId, msg.sender, side, amount, lifo);
    }

    function updatePost(uint256 postId) external {
        PostState storage ps = posts[postId];

        uint256 epoch = _currentEpoch();
        _refreshSMax(epoch);

        uint256 last = ps.lastUpdatedEpoch;
        if (last == 0 || epoch <= last) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        uint256 epochsElapsed = epoch - last;
        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];

        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;

        if (T == 0 || sMax == 0) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        bool supportWins = vsNum > 0;
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);

        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / sMax;

        uint256 rMin = (ratePolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;

        uint256 rEff = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);

        (uint256 mintS, uint256 burnS) = _applyEpoch(qs, supportWins, true, rEff);
        (uint256 mintC, uint256 burnC) = _applyEpoch(qc, supportWins, false, rEff);

        if (mintS + mintC > 0) {
            VSP_TOKEN.mint(address(this), mintS + mintC);
            emit EpochMinted(postId, mintS + mintC);
        }

        if (burnS + burnC > 0) {
            VSP_TOKEN.burn(burnS + burnC);
            emit EpochBurned(postId, burnS + burnC);
        }

        _recomputePostTotals(postId);
        ps.lastUpdatedEpoch = epoch;

        emit PostUpdated(postId, epoch, qs.total, qc.total);
    }

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    function _refreshSMax(uint256 currentEpoch) internal {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) return;

        uint256 epochsElapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (epochsElapsed > SMAX_MAX_DECAY_EPOCHS) {
            epochsElapsed = SMAX_MAX_DECAY_EPOCHS;
        }

        uint256 decayed = sMax;
        for (uint256 i = 0; i < epochsElapsed; i++) {
            decayed = (decayed * SMAX_DECAY_RATE_RAY) / RAY;
            if (decayed == 0) break;
        }

        sMax = decayed;
        sMaxLastUpdatedEpoch = currentEpoch;
    }

    function _addLot(uint256 postId, uint8 side, uint256 amount, address staker) internal {
        SideQueue storage q = posts[postId].sides[side];

        uint256 newTotal = q.total + amount;
        q.lots.push(
            StakeLot({
                staker: staker,
                amount: amount,
                side: side,
                begin: q.total,
                end: newTotal,
                mid: (q.total + newTotal) / 2,
                entryEpoch: _currentEpoch()
            })
        );

        q.total = newTotal;

        _refreshSMax(_currentEpoch());
        uint256 TT = posts[postId].sides[0].total + posts[postId].sides[1].total;
        if (TT > sMax) sMax = TT;
    }

    function _recomputePostTotals(uint256 postId) internal {
        uint256 A = _recomputeSide(posts[postId].sides[0]);
        uint256 C = _recomputeSide(posts[postId].sides[1]);

        _refreshSMax(_currentEpoch());
        uint256 TT = A + C;
        if (TT > sMax) sMax = TT;
    }

    function _recomputeSide(SideQueue storage q) internal returns (uint256 total) {
        uint256 cursor;
        uint256 write;

        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            uint256 begin = cursor;
            cursor += lot.amount;
            lot.begin = begin;
            lot.end = cursor;
            lot.mid = (begin + cursor) / 2;

            if (write != i) q.lots[write] = lot;
            write++;
        }

        while (q.lots.length > write) q.lots.pop();
        q.total = cursor;
        return cursor;
    }

    function _applyEpoch(
        SideQueue storage q,
        bool supportWins,
        bool isSupportSide,
        uint256 rEff
    ) internal returns (uint256 minted, uint256 burned) {
        if (q.total == 0 || rEff == 0 || sMax == 0) return (0, 0);

        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);

        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            uint256 wRay = (lot.mid * RAY) / sMax;
            uint256 delta = (lot.amount * rEff * wRay) / (RAY * RAY);

            if (delta == 0) continue;

            if (aligned) {
                lot.amount += delta;
                minted += delta;
            } else {
                uint256 loss = delta > lot.amount ? lot.amount : delta;
                lot.amount -= loss;
                burned += loss;
            }
        }
    }

    uint256[50] private __gap;
}

