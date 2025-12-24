// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";

/// @title StakeEngine
/// @notice Handles staking, queue positions, and epoch-based growth/decay.
///         This version settles each epoch symmetrically:
///         - Winners: lot.amount increases; VSP is minted to this contract.
///         - Losers:  lot.amount decreases (capped at principal); VSP is burned from this contract.
///         Gains/losses accrue to the queue to preserve the “queue-shape feedback” mechanic.
contract StakeEngine {
    // ------------------------------------------------------------------------
    // Constants & Types
    // ------------------------------------------------------------------------
    uint8 public constant SIDE_SUPPORT = 0;
    uint8 public constant SIDE_CHALLENGE = 1;

    struct StakeLot {
        address staker;
        uint256 amount;
        uint8 side;        // 0 = support, 1 = challenge
        uint256 begin;     // queue-position start
        uint256 end;       // queue-position end
        uint256 mid;       // (begin + end) / 2
        uint256 entryEpoch;
    }

    struct SideQueue {
        StakeLot[] lots;
        uint256 total; // sum of lot.amount on this side
    }

    struct PostState {
        SideQueue[2] sides; // 0 = support, 1 = challenge
        uint256 lastUpdatedEpoch;
    }

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------

    /// @notice ERC20 surface (transfer / transferFrom / approve)
    IERC20 public immutable ERC20_TOKEN;

    /// @notice Protocol surface (mint / burn)
    IVSPToken public immutable VSP_TOKEN;

    /// postId => state
    mapping(uint256 => PostState) private posts;

    /// Global maximum total stake across all posts (monotonic: never decreases).
    uint256 public sMax;

    // Epoch configuration
    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    // Economic parameters (ray = 1e18)
    uint256 public constant R_MIN_ANNUAL = 0;       // 0% baseline when VS is 0
    uint256 public constant R_MAX_ANNUAL = 50e16;   // 50% APY max (0.5 * 1e18)
    uint256 public constant P_MIN = 1e17;           // 0.1
    uint256 public constant P_MAX = 1e18;           // 1.0
    uint256 public constant ALPHA = 1;              // P_raw = xRay^1

    /// If T < postingFeeThreshold, treat post as economically neutral.
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
    event StakeAdded(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);
    event StakeWithdrawn(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount, bool lifo);
    event PostUpdated(uint256 indexed postId, uint256 epoch, uint256 supportTotal, uint256 challengeTotal);
    event EpochMinted(uint256 indexed postId, uint256 amount);
    event EpochBurned(uint256 indexed postId, uint256 amount);

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------
    constructor(address vspToken_) {
        if (vspToken_ == address(0)) revert ZeroAddressToken();
        ERC20_TOKEN = IERC20(vspToken_);
        VSP_TOKEN = IVSPToken(vspToken_);
    }

    // ------------------------------------------------------------------------
    // External API: Stake / Withdraw
    // ------------------------------------------------------------------------

    /// @notice Stake VSP on a post, on either support or challenge side.
    function stake(uint256 postId, uint8 side, uint256 amount) external {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        // Pull VSP from user (ERC20)
        bool ok = ERC20_TOKEN.transferFrom(msg.sender, address(this), amount);
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

        // Return VSP to user (ERC20)
        bool ok = ERC20_TOKEN.transfer(msg.sender, amount);
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
        uint256 last = ps.lastUpdatedEpoch;

        if (last == 0) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }
        if (epoch <= last) return;

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

        int256 vsNumerator = int256(2 * A) - int256(T);
        if (vsNumerator == 0) {
            ps.lastUpdatedEpoch = epoch;
            return;
        }

        bool supportWins = vsNumerator > 0;
        uint256 absVS = uint256(vsNumerator > 0 ? vsNumerator : -vsNumerator);

        uint256 vRay = (absVS * 1e18) / T;
        uint256 xRay = (T * 1e18) / sMax;
        uint256 pRay = _clamp(xRay, P_MIN, P_MAX);

        uint256 rMinEpoch = (R_MIN_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rMaxEpoch = (R_MAX_ANNUAL * EPOCH_LENGTH * epochsElapsed) / YEAR_IN_SECONDS;
        uint256 rSpan = rMaxEpoch > rMinEpoch ? (rMaxEpoch - rMinEpoch) : 0;

        uint256 rEff = rMinEpoch;
        if (rSpan > 0 && vRay > 0 && pRay > 0) {
            rEff += ((rSpan * vRay) / 1e18 * pRay) / 1e18;
        }

        (uint256 mintS, uint256 burnS) = _applyEpochToSide(qs, supportWins, true, rEff);
        (uint256 mintC, uint256 burnC) = _applyEpochToSide(qc, supportWins, false, rEff);

        uint256 totalMint = mintS + mintC;
        uint256 totalBurn = burnS + burnC;

        if (totalMint > 0) {
            VSP_TOKEN.mint(address(this), totalMint);
            emit EpochMinted(postId, totalMint);
        }
        if (totalBurn > 0) {
            VSP_TOKEN.burn(totalBurn);
            emit EpochBurned(postId, totalBurn);
        }

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
        supportTotal = ps.sides[SIDE_SUPPORT].total;
        challengeTotal = ps.sides[SIDE_CHALLENGE].total;
    }

    function getLots(uint256 postId, uint8 side)
        external
        view
        returns (StakeLot[] memory)
    {
        if (side > 1) revert InvalidSide();
        return posts[postId].sides[side].lots;
    }

    // ------------------------------------------------------------------------
    // Internal helpers (unchanged logic)
    // ------------------------------------------------------------------------

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    function _addLot(uint256 postId, uint8 side, uint256 amount, address staker) internal {
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];

        uint256 newTotal = q.total + amount;

        StakeLot memory lot = StakeLot({
            staker: staker,
            amount: amount,
            side: side,
            begin: q.total,
            end: newTotal,
            mid: (q.total + newTotal) / 2,
            entryEpoch: _currentEpoch()
        });

        q.lots.push(lot);
        q.total = newTotal;

        uint256 TT = ps.sides[SIDE_SUPPORT].total + ps.sides[SIDE_CHALLENGE].total;
        if (TT > sMax) sMax = TT;
    }

    function _recomputePostTotals(uint256 postId) internal {
        PostState storage ps = posts[postId];
        uint256 A = _recomputeSide(ps.sides[SIDE_SUPPORT]);
        uint256 C = _recomputeSide(ps.sides[SIDE_CHALLENGE]);
        uint256 TT = A + C;
        if (TT > sMax) sMax = TT;
    }

    function _recomputeSide(SideQueue storage q) internal returns (uint256 total) {
        uint256 len = q.lots.length;
        uint256 cursor = 0;
        uint256 write = 0;

        for (uint256 i = 0; i < len; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            uint256 begin = cursor;
            cursor += lot.amount;
            uint256 end = cursor;

            lot.begin = begin;
            lot.end = end;
            lot.mid = (begin + end) / 2;

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

        uint256 len = q.lots.length;
        for (uint256 i = 0; i < len; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            uint256 wRay = (lot.mid * 1e18) / sMax;
            if (wRay == 0) continue;

            uint256 rUserAbs = (rEff * wRay) / 1e18;
            if (rUserAbs == 0) continue;

            uint256 delta = (lot.amount * rUserAbs) / 1e18;
            if (delta == 0) continue;

            if (aligned) {
                lot.amount += delta;
                minted += delta;
            } else {
                uint256 loss = delta >= lot.amount ? lot.amount : delta;
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

