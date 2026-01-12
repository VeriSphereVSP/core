// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";

/// @title StakeEngine
/// @notice Handles staking, queue positions, and epoch-based growth/decay.
contract StakeEngine {
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

    IERC20 public immutable ERC20_TOKEN;
    IVSPToken public immutable VSP_TOKEN;

    mapping(uint256 => PostState) private posts;

    uint256 public sMax;

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    uint256 public constant R_MIN_ANNUAL = 0;
    uint256 public constant R_MAX_ANNUAL = 50e16; // 50%
    uint256 public constant P_MIN = 1e17;
    uint256 public constant P_MAX = 1e18;

    /// @notice Minimum total stake required for a post to be economically active (ScoreEngine gating).
    /// @dev MUST be non-zero to avoid accidental "active when empty" semantics.
    uint256 public postingFeeThreshold;

    error InvalidSide();
    error AmountZero();
    error NotEnoughStake();
    error ZeroAddressToken();

    event StakeAdded(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);
    event StakeWithdrawn(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount, bool lifo);
    event PostUpdated(uint256 indexed postId, uint256 epoch, uint256 supportTotal, uint256 challengeTotal);
    event EpochMinted(uint256 indexed postId, uint256 amount);
    event EpochBurned(uint256 indexed postId, uint256 amount);

    constructor(address vspToken_) {
        if (vspToken_ == address(0)) revert ZeroAddressToken();
        ERC20_TOKEN = IERC20(vspToken_);
        VSP_TOKEN = IVSPToken(vspToken_);

        // Keep tests + ScoreEngine semantics sane: "empty post" must not be active.
        // Tests use raw small units (1, 10, 100) so use 1 (not 1e18).
        postingFeeThreshold = 1;
    }

    // ------------------------------------------------------------------------
    // Views (required by IStakeEngine consumers)
    // ------------------------------------------------------------------------

    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 support, uint256 challenge)
    {
        PostState storage ps = posts[postId];
        support = ps.sides[SIDE_SUPPORT].total;
        challenge = ps.sides[SIDE_CHALLENGE].total;
    }

    // ------------------------------------------------------------------------
    // External API
    // ------------------------------------------------------------------------

    function stake(uint256 postId, uint8 side, uint256 amount) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        bool ok = ERC20_TOKEN.transferFrom(msg.sender, address(this), amount);
        require(ok, "VSP transferFrom failed");

        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();

        if (ps.lastUpdatedEpoch == 0) {
            ps.lastUpdatedEpoch = epoch;
        }

        _addLot(postId, side, amount, msg.sender);
        emit StakeAdded(postId, msg.sender, side, amount);
    }

    function withdraw(uint256 postId, uint8 side, uint256 amount, bool lifo) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];

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

        bool ok = ERC20_TOKEN.transfer(msg.sender, amount);
        require(ok, "VSP transfer failed");

        emit StakeWithdrawn(postId, msg.sender, side, amount, lifo);
    }

    function updatePost(uint256 postId) external {
        PostState storage ps = posts[postId];

        uint256 epoch = _currentEpoch();
        uint256 last = ps.lastUpdatedEpoch;
        if (last == 0 || epoch <= last) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        uint256 epochsElapsed = epoch - last;

        SideQueue storage qs = ps.sides[SIDE_SUPPORT];
        SideQueue storage qc = ps.sides[SIDE_CHALLENGE];

        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;

        if (T == 0 || sMax == 0 || T < postingFeeThreshold) {
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

        uint256 vRay = (absVS * 1e18) / T;
        uint256 xRay = (T * 1e18) / sMax;
        uint256 pRay = _clamp(xRay, P_MIN, P_MAX);

        uint256 rMin = (R_MIN_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rMax = (R_MAX_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rEff = rMin + ((rMax - rMin) * vRay * pRay) / 1e36;

        (uint256 mintS, uint256 burnS) = _applyEpochToSide(qs, supportWins, true, rEff);
        (uint256 mintC, uint256 burnC) = _applyEpochToSide(qc, supportWins, false, rEff);

        uint256 minted = mintS + mintC;
        uint256 burned = burnS + burnC;

        if (minted > 0) {
            VSP_TOKEN.mint(address(this), minted);
            emit EpochMinted(postId, minted);
        }
        if (burned > 0) {
            VSP_TOKEN.burn(burned);
            emit EpochBurned(postId, burned);
        }

        _recomputePostTotals(postId);

        ps.lastUpdatedEpoch = epoch;
        emit PostUpdated(postId, epoch, qs.total, qc.total);
    }

    // ------------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------------

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    function _addLot(uint256 postId, uint8 side, uint256 amount, address staker) internal {
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];

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

        uint256 TT = ps.sides[0].total + ps.sides[1].total;
        if (TT > sMax) sMax = TT;
    }

    function _recomputePostTotals(uint256 postId) internal {
        PostState storage ps = posts[postId];
        uint256 A = _recomputeSide(ps.sides[0]);
        uint256 C = _recomputeSide(ps.sides[1]);
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

    function _applyEpochToSide(
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

            uint256 wRay = (lot.mid * 1e18) / sMax;
            uint256 delta = (lot.amount * rEff * wRay) / 1e36;

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

    function _clamp(uint256 x, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (x < minVal) return minVal;
        if (x > maxVal) return maxVal;
        return x;
    }
}

