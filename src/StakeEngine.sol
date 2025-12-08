// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IVSPToken.sol";

/// @title StakeEngine
/// @notice Handles staking, queue positions, and epoch-based growth/decay.
/// All stake totals live here; PostRegistry is unaware of stake.
contract StakeEngine {
    // ------------------------------------------------------------------------
    // Constants & Types
    // ------------------------------------------------------------------------

    uint8 public constant SIDE_SUPPORT   = 0;
    uint8 public constant SIDE_CHALLENGE = 1;

    struct StakeLot {
        address staker;
        uint256 amount;
        uint8   side;        // 0 = support, 1 = challenge
        uint256 begin;       // queue-position start
        uint256 end;         // queue-position end
        uint256 mid;         // (begin + end) / 2
        uint256 entryEpoch;  // epoch when the lot was created
    }

    struct SideQueue {
        StakeLot[] lots;
        uint256 total;        // sum of lot.amount on this side
    }

    struct PostState {
        SideQueue[2] sides;   // 0 = support, 1 = challenge
        uint256 lastUpdatedEpoch;
    }

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------

    IVSPToken public immutable VSP_TOKEN;

    // postId => state
    mapping(uint256 => PostState) private posts;

    // Global maximum total stake across all posts (monotonic: never decreases).
    uint256 public sMax;

    // Epoch configuration
    uint256 public constant EPOCH_LENGTH    = 1 days;
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    // Economic parameters (ray = 1e18)
    uint256 public constant R_MIN_ANNUAL = 0;         // 0% baseline when VS is 0
    uint256 public constant R_MAX_ANNUAL = 50e16;     // 50% APY max (0.5 * 1e18)
    uint256 public constant P_MIN        = 1e17;      // 0.1
    uint256 public constant P_MAX        = 1e18;      // 1.0
    uint256 public constant ALPHA        = 1;         // P_raw = xRay^1

    // If T < postingFeeThreshold, treat post as economically neutral.
    uint256 public postingFeeThreshold;

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error InvalidSide();
    error AmountZero();
    error NotEnoughStake();
    error ZeroAddressToken();

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event StakeAdded(
        uint256 indexed postId,
        address indexed staker,
        uint8 side,
        uint256 amount
    );

    event StakeWithdrawn(
        uint256 indexed postId,
        address indexed staker,
        uint8 side,
        uint256 amount,
        bool lifo
    );

    event PostUpdated(
        uint256 indexed postId,
        uint256 epoch,
        uint256 supportTotal,
        uint256 challengeTotal
    );

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    constructor(address vspToken_) {
        if (vspToken_ == address(0)) revert ZeroAddressToken();
        VSP_TOKEN = IVSPToken(vspToken_);
    }

    // ------------------------------------------------------------------------
    // External API: Stake / Withdraw
    // ------------------------------------------------------------------------

    /// @notice Stake VSP on a post, on either support or challenge side.
    function stake(
        uint256 postId,
        uint8 side,
        uint256 amount
    ) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        // Pull VSP from user
        bool ok = VSP_TOKEN.transferFrom(msg.sender, address(this), amount);
        require(ok, "VSP transferFrom failed");

        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();

        // Initialize epoch tracking on first activity
        if (ps.lastUpdatedEpoch == 0) {
            ps.lastUpdatedEpoch = epoch;
        }

        _addLot(postId, side, amount, msg.sender);

        emit StakeAdded(postId, msg.sender, side, amount);
    }

    /// @notice Withdraw stake from a post, picking FIFO or LIFO across caller's lots.
    function withdraw(
        uint256 postId,
        uint8 side,
        uint256 amount,
        bool lifo
    ) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];

        uint256 remaining = amount;
        uint256 len = q.lots.length;

        if (len == 0) revert NotEnoughStake();

        if (lifo) {
            // Latest to earliest
            for (uint256 i = len; i > 0 && remaining > 0; i--) {
                StakeLot storage lot = q.lots[i - 1];
                if (lot.staker != msg.sender) continue;
                if (lot.amount == 0) continue;

                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining  -= take;
            }
        } else {
            // Earliest to latest
            for (uint256 i = 0; i < len && remaining > 0; i++) {
                StakeLot storage lot = q.lots[i];
                if (lot.staker != msg.sender) continue;
                if (lot.amount == 0) continue;

                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining  -= take;
            }
        }

        if (remaining > 0) revert NotEnoughStake();

        // Recompute queue positions and global totals for this post
        _recomputePostTotals(postId);

        // Return VSP to user
        bool ok = VSP_TOKEN.transfer(msg.sender, amount);
        require(ok, "VSP transfer failed");

        emit StakeWithdrawn(postId, msg.sender, side, amount, lifo);
    }

    // ------------------------------------------------------------------------
    // External API: Epoch update
    // ------------------------------------------------------------------------

    /// @notice Apply growth/decay for all lots on a post based on the last epochs.
    /// @dev Anyone may call; typically a keeper or backend.
    function updatePost(uint256 postId) external {
        PostState storage ps = posts[postId];

        uint256 epoch = _currentEpoch();
        uint256 last  = ps.lastUpdatedEpoch;

        if (last == 0) {
            // No activity yet; initialize clock only.
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        if (epoch <= last) {
            // Already updated this epoch (or time went backwards).
            return;
        }

        uint256 epochsElapsed = epoch - last;

        SideQueue storage qs = ps.sides[SIDE_SUPPORT];
        SideQueue storage qc = ps.sides[SIDE_CHALLENGE];

        uint256 A = qs.total;       // support
        uint256 D = qc.total;       // challenge
        uint256 T = A + D;          // total stake

        if (T == 0 || sMax == 0 || T < postingFeeThreshold) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        // VS numerator: 2A - T (sign determines winner)
        int256 vsNumerator = int256(2 * A) - int256(T);
        if (vsNumerator == 0) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        bool supportWins = vsNumerator > 0;
        uint256 absVS    = uint256(vsNumerator > 0 ? vsNumerator : -vsNumerator);

        // vRay = absVS / T        (0..1 in ray)
        uint256 vRay = (absVS * 1e18) / T;

        // xRay = T / sMax         (0..1 in ray)
        uint256 xRay = (T * 1e18) / sMax;

        // P_raw = xRay^ALPHA; with ALPHA = 1 => P_raw = xRay
        uint256 pRaw = xRay;
        uint256 pRay = _clamp(pRaw, P_MIN, P_MAX);

        // Convert annual rates to per-epoch (scaled by epochsElapsed)
        uint256 rMinEpoch = (R_MIN_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rMaxEpoch = (R_MAX_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rSpan     = rMaxEpoch > rMinEpoch ? (rMaxEpoch - rMinEpoch) : 0;

        // rEff = rMinEpoch + rSpan * vRay * pRay / 1e36
        uint256 rEff = rMinEpoch;
        if (rSpan > 0 && vRay > 0 && pRay > 0) {
            uint256 tmp = (rSpan * vRay) / 1e18;
            tmp = (tmp * pRay) / 1e18;
            rEff += tmp;
        }

        // Apply to both sides
        _applyEpochToSide(qs, supportWins, true,  rEff);
        _applyEpochToSide(qc, supportWins, false, rEff);

        // Recompute and update sMax
        _recomputePostTotals(postId);

        ps.lastUpdatedEpoch = epoch;

        emit PostUpdated(postId, epoch, qs.total, qc.total);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 supportTotal, uint256 challengeTotal)
    {
        PostState storage ps = posts[postId];
        supportTotal   = ps.sides[SIDE_SUPPORT].total;
        challengeTotal = ps.sides[SIDE_CHALLENGE].total;
    }

    function getLots(
        uint256 postId,
        uint8 side
    ) external view returns (StakeLot[] memory) {
        if (side > 1) revert InvalidSide();
        return posts[postId].sides[side].lots;
    }

    // ------------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------------

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    function _addLot(
        uint256 postId,
        uint8 side,
        uint256 amount,
        address staker
    ) internal {
        PostState storage ps = posts[postId];
        SideQueue storage q  = ps.sides[side];

        uint256 newTotal = q.total + amount;

        // Queue is counted from last to first logically:
        // begin = old total, end = new total, mid = average.
        StakeLot memory lot = StakeLot({
            staker:     staker,
            amount:     amount,
            side:       side,
            begin:      q.total,
            end:        newTotal,
            mid:        (q.total + newTotal) / 2,
            entryEpoch: _currentEpoch()
        });

        q.lots.push(lot);
        q.total = newTotal;

        // Update global sMax (monotonic)
        uint256 A = ps.sides[SIDE_SUPPORT].total;
        uint256 C = ps.sides[SIDE_CHALLENGE].total;
        uint256 T = A + C;
        if (T > sMax) {
            sMax = T;
        }
    }

    function _recomputePostTotals(uint256 postId) internal {
        PostState storage ps = posts[postId];

        uint256 A = _recomputeSide(ps.sides[SIDE_SUPPORT]);
        uint256 C = _recomputeSide(ps.sides[SIDE_CHALLENGE]);

        uint256 T = A + C;
        if (T > sMax) {
            sMax = T;
        }
    }

    function _recomputeSide(SideQueue storage q) internal returns (uint256 total) {
        uint256 len    = q.lots.length;
        uint256 cursor = 0;
        uint256 write  = 0;

        for (uint256 i = 0; i < len; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            uint256 begin = cursor;
            cursor       += lot.amount;
            uint256 end   = cursor;

            lot.begin = begin;
            lot.end   = end;
            lot.mid   = (begin + end) / 2;

            if (write != i) {
                q.lots[write] = lot;
            }
            write++;
        }

        // Trim trailing empty slots
        while (q.lots.length > write) {
            q.lots.pop();
        }

        q.total = cursor;
        return cursor;
    }

    function _applyEpochToSide(
        SideQueue storage q,
        bool supportWins,
        bool isSupportSide,
        uint256 rEff
    ) internal {
        if (q.total == 0 || rEff == 0 || sMax == 0) return;

        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);

        uint256 len = q.lots.length;
        for (uint256 i = 0; i < len; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            // Positional weight: wRay = mid / sMax
            uint256 wRay = (lot.mid * 1e18) / sMax;
            if (wRay == 0) continue;

            // rUserAbs = rEff * wRay / 1e18
            uint256 rUserAbs = (rEff * wRay) / 1e18;
            if (rUserAbs == 0) continue;

            // delta = amount * rUserAbs / 1e18
            uint256 delta = (lot.amount * rUserAbs) / 1e18;
            if (delta == 0) continue;

            if (aligned) {
                lot.amount += delta;
            } else {
                lot.amount = delta >= lot.amount ? 0 : lot.amount - delta;
            }
        }
    }

    function _clamp(
        uint256 x,
        uint256 minVal,
        uint256 maxVal
    ) internal pure returns (uint256) {
        if (x < minVal) return minVal;
        if (x > maxVal) return maxVal;
        return x;
    }
}

