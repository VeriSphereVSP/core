// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./interfaces/IVSPToken.sol";

/// @title StakeEngine
/// @notice Handles staking, queue positions, and epoch-based growth/decay.
contract StakeEngine {
    // ------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------

    uint8 public constant SIDE_SUPPORT = 0;
    uint8 public constant SIDE_CHALLENGE = 1;

    struct StakeLot {
        address staker;
        uint256 amount;
        uint8 side;          // 0 = support, 1 = challenge
        uint256 begin;       // queue position start (global from last toward first)
        uint256 end;         // queue position end
        uint256 mid;         // (begin + end) / 2
        uint256 entryEpoch;  // epoch at which this lot was created
    }

    struct SideQueue {
        StakeLot[] lots;
        uint256 total; // sum of lot.amount on this side
    }

    struct PostState {
        SideQueue[2] sides;      // [0] support, [1] challenge
        uint256 lastUpdatedEpoch;
    }

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------

    IVSPToken public immutable VSP_TOKEN;

    // postId => state
    mapping(uint256 => PostState) private posts;

    // Global maximum total stake across all posts (monotonic).
    uint256 public sMax;

    // Epoch parameters
    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    // Economic parameters (ray, 1e18)
    // These are simple MVP constants; governance can manage them later.
    uint256 public constant R_MIN_ANNUAL = 0;         // 0% baseline when VS is 0
    uint256 public constant R_MAX_ANNUAL = 50e16;     // 50% APY max (0.5 * 1e18)
    uint256 public constant P_MIN = 1e17;             // 0.1
    uint256 public constant P_MAX = 1e18;             // 1.0
    uint256 public constant ALPHA = 1;                // P_raw = xRay^1

    // Posting fee threshold for economics (optional)
    uint256 public postingFeeThreshold; // if T < threshold => treat as neutral

    // ------------------------------------------------------------------------
    // Errors and events
    // ------------------------------------------------------------------------

    error InvalidSide();
    error AmountZero();
    error NotEnoughStake();
    error ZeroAddressToken();

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
    // External API
    // ------------------------------------------------------------------------

    /// @notice Stake VSP on a post, on either support or challenge side.
    /// @param postId The target post id.
    /// @param side   0 = support, 1 = challenge.
    /// @param amount Amount of VSP to stake (must be non-zero).
    function stake(
        uint256 postId,
        uint8 side,
        uint256 amount
    ) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        // Pull VSP from staker into this contract
        bool ok = VSP_TOKEN.transferFrom(msg.sender, address(this), amount);
        require(ok, "VSP transferFrom failed");

        PostState storage ps = posts[postId];

        // Initialize lastUpdatedEpoch on first activity
        uint256 currentEpoch = _currentEpoch();
        if (ps.lastUpdatedEpoch == 0) {
            ps.lastUpdatedEpoch = currentEpoch;
        }

        // Append lot and recompute queue positions
        _addLot(postId, side, amount, msg.sender);

        emit StakeAdded(postId, msg.sender, side, amount);
    }

    /// @notice Withdraw stake from a post, choosing FIFO or LIFO across your own lots.
    /// @param postId The target post id.
    /// @param side   0 = support, 1 = challenge.
    /// @param amount Total amount to withdraw.
    /// @param lifo   If true, withdraw from latest lots first; if false, earliest first.
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
            for (uint256 idx = len; idx > 0 && remaining > 0; idx--) {
                StakeLot storage lot = q.lots[idx - 1];
                if (lot.staker != msg.sender) continue;
                if (lot.amount == 0) continue;

                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining -= take;
            }
        } else {
            // Earliest to latest
            for (uint256 idx = 0; idx < len && remaining > 0; idx++) {
                StakeLot storage lot = q.lots[idx];
                if (lot.staker != msg.sender) continue;
                if (lot.amount == 0) continue;

                uint256 take = lot.amount < remaining ? lot.amount : remaining;
                lot.amount -= take;
                remaining -= take;
            }
        }

        if (remaining > 0) revert NotEnoughStake();

        // Recompute queue positions and totals for this side and update global sMax
        _recomputePostTotals(postId);

        // Transfer VSP out to staker
        bool ok = VSP_TOKEN.transfer(msg.sender, amount);
        require(ok, "VSP transfer failed");

        emit StakeWithdrawn(postId, msg.sender, side, amount, lifo);
    }

    /// @notice Apply daily epoch growth/decay to all lots for a post.
    /// @dev Anyone may call; typically a keeper or backend.
    function updatePost(uint256 postId) external {
        PostState storage ps = posts[postId];

        uint256 currentEpoch = _currentEpoch();
        uint256 lastEpoch = ps.lastUpdatedEpoch;

        if (lastEpoch == 0) {
            // No activity yet; just initialize clock.
            ps.lastUpdatedEpoch = currentEpoch;
            return;
        }

        if (currentEpoch <= lastEpoch) {
            // Already updated this epoch or in the future (impossible under normal conditions).
            return;
        }

        uint256 epochsElapsed = currentEpoch - lastEpoch;

        // Compute post totals A, D, T
        SideQueue storage qs = ps.sides[SIDE_SUPPORT];
        SideQueue storage qc = ps.sides[SIDE_CHALLENGE];

        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;

        if (T == 0 || sMax == 0 || T < postingFeeThreshold) {
            // Nothing staked or under threshold; update epoch marker only.
            ps.lastUpdatedEpoch = currentEpoch;
            return;
        }

        // Compute VS numerator and sign
        // vsNumerator = 2*A - T
        int256 vsNumerator = int256(2 * A) - int256(T);

        if (vsNumerator == 0) {
            // Neutral verity; no economic change.
            ps.lastUpdatedEpoch = currentEpoch;
            return;
        }

        bool supportWins = vsNumerator > 0;
        uint256 absVsNumerator = uint256(vsNumerator > 0 ? vsNumerator : -vsNumerator);

        // vRay = abs(VS)/100 = abs(2A - T) / T, scaled by 1e18
        uint256 vRay = (absVsNumerator * 1e18) / T;

        // xRay = T / sMax
        uint256 xRay = (T * 1e18) / sMax;

        // P_raw = xRay^ALPHA; ALPHA = 1 => P_raw = xRay
        uint256 pRaw = xRay;
        uint256 pRay = _clamp(pRaw, P_MIN, P_MAX);

        // Annual to per-epoch rate, scaled for epochsElapsed
        uint256 rMinEpoch = (R_MIN_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rMaxEpoch = (R_MAX_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rSpanEpoch = rMaxEpoch > rMinEpoch ? (rMaxEpoch - rMinEpoch) : 0;

        // r_eff = rMinEpoch + rSpanEpoch * vRay * pRay / 1e36
        uint256 rEff = rMinEpoch;
        if (rSpanEpoch > 0 && vRay > 0 && pRay > 0) {
            uint256 tmp = (rSpanEpoch * vRay) / 1e18;
            tmp = (tmp * pRay) / 1e18;
            rEff += tmp;
        }

        // Apply per-lot growth/decay on both sides
        _applyEpochToSide(qs, supportWins, true, rEff);
        _applyEpochToSide(qc, supportWins, false, rEff);

        // Recompute queue positions and totals for both sides, and update sMax
        _recomputePostTotals(postId);

        ps.lastUpdatedEpoch = currentEpoch;

        emit PostUpdated(postId, currentEpoch, qs.total, qc.total);
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
        supportTotal = ps.sides[SIDE_SUPPORT].total;
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
        SideQueue storage q = ps.sides[side];

        // Queue is counted from last to first logically.
        // We treat "end" as current total, and "begin" as total - amount.
        // So earliest stakes have smallest begin, latest stakes have largest begin.
        uint256 newTotal = q.total + amount;
        uint256 lotBegin = q.total;
        uint256 lotEnd = newTotal;
        uint256 lotMid = (lotBegin + lotEnd) / 2;

        StakeLot memory lot = StakeLot({
            staker: staker,
            amount: amount,
            side: side,
            begin: lotBegin,
            end: lotEnd,
            mid: lotMid,
            entryEpoch: _currentEpoch()
        });

        q.lots.push(lot);
        q.total = newTotal;

        // Update global sMax
        uint256 supportTotal = ps.sides[SIDE_SUPPORT].total;
        uint256 challengeTotal = ps.sides[SIDE_CHALLENGE].total;
        uint256 T = supportTotal + challengeTotal;
        if (T > sMax) {
            sMax = T;
        }
    }

    function _recomputePostTotals(uint256 postId) internal {
        PostState storage ps = posts[postId];

        // Recompute for both sides
        uint256 supportTotal = _recomputeSide(ps.sides[SIDE_SUPPORT]);
        uint256 challengeTotal = _recomputeSide(ps.sides[SIDE_CHALLENGE]);

        uint256 T = supportTotal + challengeTotal;
        if (T > sMax) {
            sMax = T;
        }
    }

    function _recomputeSide(SideQueue storage q) internal returns (uint256 newTotal) {
        uint256 len = q.lots.length;
        uint256 cursor = 0;
        uint256 writeIndex = 0;

        for (uint256 i = 0; i < len; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) {
                // Skip; will be dropped.
                continue;
            }

            uint256 begin = cursor;
            cursor += lot.amount;
            uint256 end = cursor;
            uint256 mid = (begin + end) / 2;

            lot.begin = begin;
            lot.end = end;
            lot.mid = mid;

            if (writeIndex != i) {
                q.lots[writeIndex] = lot;
            }
            writeIndex++;
        }

        // Trim array to remove zeros
        if (writeIndex < len) {
            for (uint256 j = len; j > writeIndex; j--) {
                q.lots.pop();
            }
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
        uint256 len = q.lots.length;
        if (len == 0 || rEff == 0 || sMax == 0) {
            return;
        }

        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);

        for (uint256 i = 0; i < len; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            // Positional weight: wRay = mid / sMax
            uint256 wRay = (lot.mid * 1e18) / sMax;

            if (wRay == 0) continue;

            // r_user_abs = rEff * wRay / 1e18
            uint256 rUserAbs = (rEff * wRay) / 1e18;
            if (rUserAbs == 0) continue;

            // delta = amount * rUserAbs / 1e18
            uint256 delta = (lot.amount * rUserAbs) / 1e18;
            if (delta == 0) continue;

            if (aligned) {
                lot.amount += delta;
            } else {
                if (delta >= lot.amount) {
                    lot.amount = 0;
                } else {
                    lot.amount -= delta;
                }
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

