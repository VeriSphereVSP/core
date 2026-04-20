// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";
import "./governance/StakeRatePolicy.sol";
import "./governance/GovernedUpgradeable.sol";

/// @title StakeEngine (v2)
/// @notice Manages VSP staking on posts with:
///         - Lot consolidation: one lot per user per side per post
///         - Continuous positional weighting based on stake-weighted queue coord
///         - Periodic snapshots: O(N) computation at most once per period
///         - Lazy view projection: reads are always current, O(1), no gas
///         - Post-snapshot position rescale: after each snapshot,
///           weightedPosition values are clamped to [0, sideTotal) so that
///           no lot starts the next epoch with zero posWeight
///         Supports gasless meta-transactions via ERC-2771.
contract StakeEngine is GovernedUpgradeable {
    uint8 public constant SIDE_SUPPORT = 0;
    uint8 public constant SIDE_CHALLENGE = 1;

    // ------------------------------------------------------------
    // Data structures
    // ------------------------------------------------------------

    /// @notice A consolidated stake lot — one per user per side per post.
    struct StakeLot {
        address staker;
        uint256 amount; // Current amount after last snapshot
        uint8 side;
        uint256 weightedPosition; // Stake-weighted queue position
        uint256 entryEpoch; // Epoch of first stake
    }

    struct SideQueue {
        StakeLot[] lots;
        uint256 total; // Sum of all lot amounts (as of last snapshot)
    }

    struct PostState {
        SideQueue[2] sides; // [0] = support, [1] = challenge
        uint256 lastSnapshotEpoch; // Last epoch when full O(N) update ran
        mapping(address => uint256) lotIndex0; // user => lots index + 1, support side
        mapping(address => uint256) lotIndex1; // user => lots index + 1, challenge side
    }

    // ------------------------------------------------------------
    // State variables
    // ------------------------------------------------------------

    IERC20 public ERC20_TOKEN;
    IVSPToken public VSP_TOKEN;
    StakeRatePolicy public ratePolicy;

    mapping(uint256 => PostState) private posts;

    uint256 public sMax;
    uint256 public sMaxPostId;

    struct TopPost { uint256 postId; uint256 total; }
    TopPost[3] private topPosts;


    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus;

    modifier nonReentrant() {
        require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }
    uint256 public sMaxLastUpdatedEpoch;

    uint256 public snapshotPeriod;

    /// @notice sMax decay rate per epoch, in RAY.
    ///         Default 995e15 = 0.995 = 0.5% decay per day.
    ///         Governance-configurable. Lower value = faster decay.
    ///         RAY (1e18) = no decay. Must be in (0, RAY].
    uint256 public sMaxDecayRateRay;

    /// @notice Maximum epochs of sMax decay to project in one call.
    ///         Caps gas cost when catching up stale posts.
    uint256 public sMaxDecayMaxEpochs;

    /// @notice Legacy field, retained for ABI compatibility.

    // ------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_LENGTH = 365 days;
    uint256 private constant RAY = 1e18;

    uint256 private constant DEFAULT_SNAPSHOT_PERIOD = 1 days;
    uint256 private constant DEFAULT_SMAX_DECAY_RATE_RAY = 995e15;
    uint256 private constant DEFAULT_SMAX_DECAY_MAX_EPOCHS = 3650;

    // ------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------

    error InvalidSide();
    error AmountZero();
    error OppositeSideStaked();
    error NotEnoughStake();
    error ZeroAddressToken();
    error InvalidSnapshotPeriod();
    error NoGhostLots();
    error InvalidDecayRate();
    error InvalidDecayMaxEpochs();

    // ------------------------------------------------------------
    // Events
    // ------------------------------------------------------------

    event StakeAdded(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount);
    event StakeWithdrawn(uint256 indexed postId, address indexed staker, uint8 side, uint256 amount, bool lifo);
    event PostUpdated(uint256 indexed postId, uint256 epoch, uint256 supportTotal, uint256 challengeTotal);
    event EpochMinted(uint256 indexed postId, uint256 amount);
    event EpochBurned(uint256 indexed postId, uint256 amount);
    event SnapshotPeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event LotsCompacted(uint256 indexed postId, uint8 side, uint256 removed);
    event SMaxRescanned(uint256 newSMax, uint256 newSMaxPostId);
    event SMaxDecayRateSet(uint256 oldRate, uint256 newRate);
    event SMaxDecayMaxEpochsSet(uint256 oldMax, uint256 newMax);
    event PositionsRescaled(uint256 indexed postId, uint8 side, uint256 oldMax, uint256 newCeiling);

    // ------------------------------------------------------------
    // Constructor / Initializer
    // ------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address trustedForwarder_) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(address governance_, address vspToken_, address ratePolicy_) external initializer {
        if (vspToken_ == address(0)) revert ZeroAddressToken();
        __GovernedUpgradeable_init(governance_);
        ERC20_TOKEN = IERC20(vspToken_);
        VSP_TOKEN = IVSPToken(vspToken_);
        ratePolicy = StakeRatePolicy(ratePolicy_);
        sMaxLastUpdatedEpoch = _currentEpoch();
        snapshotPeriod = DEFAULT_SNAPSHOT_PERIOD;
        sMaxDecayRateRay = DEFAULT_SMAX_DECAY_RATE_RAY;
        sMaxDecayMaxEpochs = DEFAULT_SMAX_DECAY_MAX_EPOCHS;
    }

    // ------------------------------------------------------------
    // Governance setters
    // ------------------------------------------------------------

    function setSnapshotPeriod(uint256 newPeriod) external onlyGovernance {
        if (newPeriod == 0) revert InvalidSnapshotPeriod();
        emit SnapshotPeriodSet(snapshotPeriod, newPeriod);
        snapshotPeriod = newPeriod;
    }

    /// @notice Set the sMax decay rate. Governance-only.
    ///         Must be in (0, RAY]. 995e15 = 0.5%/day, RAY = no decay.
    function setSMaxDecayRate(uint256 newRate) external onlyGovernance {
        if (newRate == 0 || newRate > RAY) revert InvalidDecayRate();
        emit SMaxDecayRateSet(sMaxDecayRateRay, newRate);
        sMaxDecayRateRay = newRate;
    }

    /// @notice Set the max epochs of sMax decay projection. Governance-only.
    function setSMaxDecayMaxEpochs(uint256 newMax) external onlyGovernance {
        if (newMax == 0) revert InvalidDecayMaxEpochs();
        emit SMaxDecayMaxEpochsSet(sMaxDecayMaxEpochs, newMax);
        sMaxDecayMaxEpochs = newMax;
    }

    /// @notice Legacy setter retained for ABI compatibility.

    function compactLots(uint256 postId, uint8 side) external onlyGovernance nonReentrant {
        if (side > 1) revert InvalidSide();
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];
        uint256 removed = 0;
        uint256 i = q.lots.length;
        while (i > 0) {
            i--;
            if (q.lots[i].amount == 0) {
                address ghostStaker = q.lots[i].staker;
                if (i == q.lots.length - 1) {
                    _setLotIndex(ps, ghostStaker, side, 0);
                    q.lots.pop();
                } else {
                    uint256 lastIdx = q.lots.length - 1;
                    StakeLot storage lastLot = q.lots[lastIdx];
                    address lastStaker = lastLot.staker;
                    q.lots[i] = lastLot;
                    _setLotIndex(ps, lastStaker, side, i + 1);
                    _setLotIndex(ps, ghostStaker, side, 0);
                    q.lots.pop();
                }
                removed++;
            }
        }
        if (removed == 0) revert NoGhostLots();

        // Recompute positions after swap-and-pop changes array layout
        _recomputeWeightedPositions(q);

        emit LotsCompacted(postId, side, removed);
    }

    // ------------------------------------------------------------
    // Read (view — always current via projection)
    // ------------------------------------------------------------

    function getPostTotals(uint256 postId) external view returns (uint256 support, uint256 challenge) {
        PostState storage ps = posts[postId];
        uint256 currentEpoch = _currentEpoch();
        uint256 snapshotEpoch = ps.lastSnapshotEpoch;
        uint256 storedS = ps.sides[0].total;
        uint256 storedC = ps.sides[1].total;
        if (snapshotEpoch == 0 || currentEpoch <= snapshotEpoch) {
            return (storedS, storedC);
        }
        return _projectTotals(ps, currentEpoch);
    }

    function getUserStake(address user, uint256 postId, uint8 side) external view returns (uint256) {
        if (side > 1) revert InvalidSide();
        PostState storage ps = posts[postId];
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx == 0) return 0;
        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount == 0) return 0;
        uint256 currentEpoch = _currentEpoch();
        uint256 snapshotEpoch = ps.lastSnapshotEpoch;
        if (snapshotEpoch == 0 || currentEpoch <= snapshotEpoch) {
            return lot.amount;
        }
        return _projectLotValue(ps, lot, currentEpoch);
    }

    function getUserLotInfo(address user, uint256 postId, uint8 side)
        external view returns (
            uint256 amount, uint256 weightedPosition, uint256 entryEpoch,
            uint256 sideTotal, uint256 positionWeight
        )
    {
        if (side > 1) revert InvalidSide();
        PostState storage ps = posts[postId];
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx == 0) return (0, 0, 0, 0, 0);
        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount == 0) return (0, 0, 0, 0, 0);

        uint256 currentEpoch = _currentEpoch();
        uint256 projectedAmount = lot.amount;
        if (ps.lastSnapshotEpoch > 0 && currentEpoch > ps.lastSnapshotEpoch) {
            projectedAmount = _projectLotValue(ps, lot, currentEpoch);
        }

        sideTotal = ps.sides[side].total;
        if (sideTotal > 0) {
            uint256 posShare = (lot.weightedPosition * RAY) / sideTotal;
            if (posShare > RAY) posShare = RAY;
            positionWeight = RAY - posShare;
        } else {
            positionWeight = RAY;
        }
        return (projectedAmount, lot.weightedPosition, lot.entryEpoch, sideTotal, positionWeight);
    }

    // ------------------------------------------------------------
    // Stake
    // ------------------------------------------------------------

    function stake(uint256 postId, uint8 side, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();
        PostState storage psCheck = posts[postId];
        uint8 opposite = 1 - side;
        uint256 oppIdx = _getLotIndex(psCheck, _msgSender(), opposite);
        if (oppIdx > 0 && psCheck.sides[opposite].lots[oppIdx - 1].amount > 0) {
            revert OppositeSideStaked();
        }
        require(ERC20_TOKEN.transferFrom(_msgSender(), address(this), amount), "VSP transfer failed");
        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        if (ps.lastSnapshotEpoch == 0) ps.lastSnapshotEpoch = epoch;
        _maybeSnapshot(postId, epoch);
        _addOrMergeLot(postId, side, amount, _msgSender());
        emit StakeAdded(postId, _msgSender(), side, amount);
    }

    // ------------------------------------------------------------
    // Withdraw
    // ------------------------------------------------------------

    function withdraw(uint256 postId, uint8 side, uint256 amount, bool /* lifo */) external nonReentrant {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();
        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();
        _maybeSnapshot(postId, epoch);
        uint256 idx = _getLotIndex(ps, _msgSender(), side);
        if (idx == 0) revert NotEnoughStake();
        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount < amount) revert NotEnoughStake();
        lot.amount -= amount;
        ps.sides[side].total -= amount;
        uint256 TT = ps.sides[0].total + ps.sides[1].total;
        _updateSMax(postId, TT);
        require(ERC20_TOKEN.transfer(_msgSender(), amount), "VSP transfer failed");
        emit StakeWithdrawn(postId, _msgSender(), side, amount, true);
    }

    // ------------------------------------------------------------
    // Permissionless update
    // ------------------------------------------------------------

    function updatePost(uint256 postId) external nonReentrant {
        uint256 epoch = _currentEpoch();
        _forceSnapshot(postId, epoch);
    }

    // ------------------------------------------------------------
    // Internal: Snapshot logic
    // ------------------------------------------------------------

    function _maybeSnapshot(uint256 postId, uint256 currentEpoch) internal {
        PostState storage ps = posts[postId];
        uint256 lastEpoch = ps.lastSnapshotEpoch;
        if (lastEpoch == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }
        uint256 periodInEpochs = snapshotPeriod / EPOCH_LENGTH;
        if (periodInEpochs == 0) periodInEpochs = 1;
        if (currentEpoch >= lastEpoch + periodInEpochs) {
            _forceSnapshot(postId, currentEpoch);
        }
    }

    function _forceSnapshot(uint256 postId, uint256 currentEpoch) internal {
        PostState storage ps = posts[postId];
        uint256 lastEpoch = ps.lastSnapshotEpoch;
        if (lastEpoch == 0 || currentEpoch <= lastEpoch) {
            if (lastEpoch == 0) ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];

        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;

        if (T == 0 || sMax == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) {
            // VS neutral — no growth/decay, but still rescale positions
            // so the invariant holds for the next epoch.
            _rescalePositions(postId, 0, qs);
            _rescalePositions(postId, 1, qc);
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        bool supportWins = vsNum > 0;
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);

        uint256 epochsElapsed = currentEpoch - lastEpoch;
        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / sMax;

        uint256 rMin = (ratePolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);

        // Apply epoch gains/losses (positions that exceed sideTotal are
        // safely clamped to zero weight inside _applyEpoch — this is
        // the one-epoch penalty before rescale fixes them).
        (uint256 mintS, uint256 burnS) = _applyEpoch(qs, supportWins, true, rBase);
        (uint256 mintC, uint256 burnC) = _applyEpoch(qc, supportWins, false, rBase);

        if (mintS + mintC > 0) {
            VSP_TOKEN.mint(address(this), mintS + mintC);
            emit EpochMinted(postId, mintS + mintC);
        }
        if (burnS + burnC > 0) {
            VSP_TOKEN.burn(burnS + burnC);
            emit EpochBurned(postId, burnS + burnC);
        }

        // Recompute totals after mints/burns
        _recomputeSideTotal(qs);
        _recomputeSideTotal(qc);

        // Rescale positions AFTER totals are final so that every lot's
        // weightedPosition is < sideTotal going into the next epoch.
        // This prevents the "dropped to zero rate" edge case where
        // earlier stakers withdrew and shrank sideTotal below later
        // stakers' positions.
        _rescalePositions(postId, 0, qs);
        _rescalePositions(postId, 1, qc);

        ps.lastSnapshotEpoch = currentEpoch;

        uint256 TT = qs.total + qc.total;
        _updateSMax(postId, TT);

        emit PostUpdated(postId, currentEpoch, qs.total, qc.total);
    }

    /// @dev Rescale weightedPositions so that max(position) < q.total.
    ///      Called after _applyEpoch + _recomputeSideTotal so that totals
    ///      reflect the final state including mints/burns.
    ///      Uses strict < (not <=) by targeting q.total - 1 when rescale
    ///      is needed, so no lot starts the next epoch at posWeight == 0.
    function _rescalePositions(uint256 postId, uint8 side, SideQueue storage q) internal {
        uint256 n = q.lots.length;
        if (n == 0 || q.total == 0) return;

        uint256 maxPos = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 p = q.lots[i].weightedPosition;
            if (p > maxPos) maxPos = p;
        }
        // Rescale if any position >= q.total (using >= not > so that
        // a position exactly equal to sideTotal is also fixed).
        if (maxPos < q.total) return;

        // Target: map maxPos to (q.total - 1) so that the highest
        // position always has posShare < RAY → posWeight > 0.
        uint256 target = q.total > 0 ? q.total - 1 : 0;
        if (target == 0) {
            // Edge case: sideTotal is 1 wei. Just zero all positions.
            for (uint256 i = 0; i < n; i++) {
                q.lots[i].weightedPosition = 0;
            }
        } else {
            for (uint256 i = 0; i < n; i++) {
                q.lots[i].weightedPosition =
                    (q.lots[i].weightedPosition * target) / maxPos;
            }
        }
        emit PositionsRescaled(postId, side, maxPos, target);
    }

    /// @dev Applies epoch gains/losses with positional weighting.
    function _applyEpoch(
        SideQueue storage q, bool supportWins, bool isSupportSide, uint256 rBase
    ) internal returns (uint256 minted, uint256 burned) {
        if (q.total == 0 || rBase == 0 || sMax == 0) return (0, 0);
        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);
        uint256 T = q.total;
        uint256 budget = (T * rBase) / RAY;

        uint256 totalWeightedStake = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;
            uint256 posShare = (lot.weightedPosition * RAY) / T;
            if (posShare > RAY) posShare = RAY;
            uint256 posWeight = RAY - posShare;
            totalWeightedStake += (lot.amount * posWeight) / RAY;
        }
        if (totalWeightedStake == 0) return (0, 0);

        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;
            uint256 posShare = (lot.weightedPosition * RAY) / T;
            if (posShare > RAY) posShare = RAY;
            uint256 posWeight = RAY - posShare;
            uint256 myWeightedStake = (lot.amount * posWeight) / RAY;
            uint256 delta = (budget * myWeightedStake) / totalWeightedStake;
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
        q.total = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            q.total += q.lots[i].amount;
        }
    }

    // ------------------------------------------------------------
    // Internal: Lot management
    // ------------------------------------------------------------

    function _addOrMergeLot(uint256 postId, uint8 side, uint256 amount, address staker) internal {
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];
        uint256 idx = _getLotIndex(ps, staker, side);
        if (idx != 0) {
            StakeLot storage existing = q.lots[idx - 1];
            uint256 oldAmount = existing.amount;
            uint256 newEntryPosition = q.total;
            existing.weightedPosition = (existing.weightedPosition * oldAmount + newEntryPosition * amount) / (oldAmount + amount);
            existing.amount = oldAmount + amount;
        } else {
            uint256 newIdx = q.lots.length;
            q.lots.push(StakeLot({ staker: staker, amount: amount, side: side, weightedPosition: q.total, entryEpoch: _currentEpoch() }));
            _setLotIndex(ps, staker, side, newIdx + 1);
        }
        q.total += amount;
        uint256 TT = ps.sides[0].total + ps.sides[1].total;
        _updateSMax(postId, TT);
    }

    function _getLotIndex(PostState storage ps, address user, uint8 side) internal view returns (uint256) {
        if (side == 0) return ps.lotIndex0[user];
        return ps.lotIndex1[user];
    }

    function _setLotIndex(PostState storage ps, address user, uint8 side, uint256 idxPlusOne) internal {
        if (side == 0) { ps.lotIndex0[user] = idxPlusOne; }
        else { ps.lotIndex1[user] = idxPlusOne; }
    }

    // ------------------------------------------------------------
    // Internal: View projection
    // ------------------------------------------------------------

    function _projectTotals(PostState storage ps, uint256 currentEpoch) internal view returns (uint256 projS, uint256 projC) {
        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];
        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;
        if (T == 0 || sMax == 0) return (A, D);
        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) return (A, D);
        bool supportWins = vsNum > 0;
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);
        uint256 epochsElapsed = currentEpoch - ps.lastSnapshotEpoch;
        uint256 projSMax = _projectSMaxDecay(currentEpoch);
        if (projSMax == 0) return (A, D);
        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / projSMax;
        uint256 rMin = (ratePolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);
        projS = _projectSideTotal(qs, supportWins, true, rBase);
        projC = _projectSideTotal(qc, supportWins, false, rBase);
    }

    function _projectSideTotal(SideQueue storage q, bool supportWins, bool isSupportSide, uint256 rBase) internal view returns (uint256 total) {
        if (q.total == 0 || rBase == 0) return q.total;
        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);
        uint256 T = q.total;
        uint256 budget = (T * rBase) / RAY;

        uint256 totalWeightedStake = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;
            uint256 posShare = (lot.weightedPosition * RAY) / T;
            if (posShare > RAY) posShare = RAY;
            uint256 posWeight = RAY - posShare;
            totalWeightedStake += (lot.amount * posWeight) / RAY;
        }
        if (totalWeightedStake == 0) return q.total;

        total = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;
            uint256 posShare = (lot.weightedPosition * RAY) / T;
            if (posShare > RAY) posShare = RAY;
            uint256 posWeight = RAY - posShare;
            uint256 myWeightedStake = (lot.amount * posWeight) / RAY;
            uint256 delta = (budget * myWeightedStake) / totalWeightedStake;
            if (aligned) {
                total += lot.amount + delta;
            } else {
                uint256 loss = delta > lot.amount ? lot.amount : delta;
                total += lot.amount - loss;
            }
        }
    }

    function _projectLotValue(PostState storage ps, StakeLot storage lot, uint256 currentEpoch) internal view returns (uint256) {
        SideQueue storage qs = ps.sides[0];
        SideQueue storage qc = ps.sides[1];
        uint256 A = qs.total;
        uint256 D = qc.total;
        uint256 T = A + D;
        if (T == 0 || sMax == 0) return lot.amount;
        int256 vsNum = int256(2 * A) - int256(T);
        if (vsNum == 0) return lot.amount;
        bool supportWins = vsNum > 0;
        bool isSupportSide = lot.side == 0;
        bool aligned = (supportWins && isSupportSide) || (!supportWins && !isSupportSide);
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);
        uint256 epochsElapsed = currentEpoch - ps.lastSnapshotEpoch;
        uint256 projSMax = _projectSMaxDecay(currentEpoch);
        if (projSMax == 0) return lot.amount;
        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / projSMax;
        if (participationRay > RAY) participationRay = RAY;
        uint256 rMin = (ratePolicy.stakeIntRateMinRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() * EPOCH_LENGTH * epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin + ((rMax - rMin) * vRay * participationRay) / (RAY * RAY);

        SideQueue storage mySide = isSupportSide ? qs : qc;
        uint256 sideTotal = mySide.total;
        if (sideTotal == 0 || rBase == 0) return lot.amount;
        uint256 budget = (sideTotal * rBase) / RAY;

        uint256 totalWeightedStake = 0;
        for (uint256 i = 0; i < mySide.lots.length; i++) {
            StakeLot storage lj = mySide.lots[i];
            if (lj.amount == 0) continue;
            uint256 posShare_j = (lj.weightedPosition * RAY) / sideTotal;
            if (posShare_j > RAY) posShare_j = RAY;
            uint256 posWeight_j = RAY - posShare_j;
            totalWeightedStake += (lj.amount * posWeight_j) / RAY;
        }
        if (totalWeightedStake == 0) return lot.amount;

        uint256 posShare = (lot.weightedPosition * RAY) / sideTotal;
        if (posShare > RAY) posShare = RAY;
        uint256 posWeight = RAY - posShare;
        uint256 myWeightedStake = (lot.amount * posWeight) / RAY;
        uint256 delta = (budget * myWeightedStake) / totalWeightedStake;
        if (aligned) {
            return lot.amount + delta;
        } else {
            uint256 loss = delta > lot.amount ? lot.amount : delta;
            return lot.amount - loss;
        }
    }

    // ------------------------------------------------------------
    // Internal: sMax management
    // ------------------------------------------------------------

    function _currentEpoch() internal view returns (uint256) { return block.timestamp / EPOCH_LENGTH; }

    function _updateSMax(uint256 postId, uint256 postTotal) internal {
        uint256 slot = type(uint256).max;
        for (uint256 i = 0; i < 3; i++) {
            if (topPosts[i].postId == postId && topPosts[i].total > 0) { slot = i; break; }
        }
        if (slot != type(uint256).max) {
            topPosts[slot].total = postTotal;
            while (slot > 0 && topPosts[slot].total > topPosts[slot - 1].total) {
                TopPost memory tmp = topPosts[slot]; topPosts[slot] = topPosts[slot - 1]; topPosts[slot - 1] = tmp; slot--;
            }
            while (slot < 2 && topPosts[slot].total < topPosts[slot + 1].total) {
                TopPost memory tmp = topPosts[slot]; topPosts[slot] = topPosts[slot + 1]; topPosts[slot + 1] = tmp; slot++;
            }
        } else {
            for (uint256 i = 0; i < 3; i++) {
                if (postTotal > topPosts[i].total) {
                    for (uint256 j = 2; j > i; j--) { topPosts[j] = topPosts[j - 1]; }
                    topPosts[i] = TopPost(postId, postTotal);
                    break;
                }
            }
        }
        for (uint256 i = 0; i < 3; i++) {
            if (topPosts[i].total == 0) topPosts[i] = TopPost(0, 0);
        }
        uint256 leaderTotal = topPosts[0].total;
        uint256 currentEpoch = _currentEpoch();
        if (leaderTotal > 0) {
            if (leaderTotal >= sMax) {
                sMax = leaderTotal; sMaxLastUpdatedEpoch = currentEpoch;
            } else {
                uint256 decayed = _applySMaxDecay(currentEpoch);
                sMax = decayed > leaderTotal ? decayed : leaderTotal;
            }
            sMaxPostId = topPosts[0].postId;
        } else {
            sMax = _applySMaxDecay(currentEpoch);
        }
    }

    function _applySMaxDecay(uint256 currentEpoch) internal returns (uint256) {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) { sMaxLastUpdatedEpoch = currentEpoch; return sMax; }
        uint256 elapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (elapsed > sMaxDecayMaxEpochs) elapsed = sMaxDecayMaxEpochs;
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) { decayed = (decayed * sMaxDecayRateRay) / RAY; if (decayed == 0) break; }
        sMax = decayed; sMaxLastUpdatedEpoch = currentEpoch;
        return decayed;
    }

    function rescanSMax(uint256[] calldata postIds) external onlyGovernance {
        for (uint256 i = 0; i < 3; i++) topPosts[i] = TopPost(0, 0);
        for (uint256 i = 0; i < postIds.length; i++) {
            uint256 pid = postIds[i];
            PostState storage ps = posts[pid];
            uint256 total = ps.sides[0].total + ps.sides[1].total;
            if (total == 0) continue;
            _updateSMax(pid, total);
        }
        emit SMaxRescanned(topPosts[0].total, topPosts[0].postId);
    }

    function getTopPosts() external view returns (uint256 p0, uint256 t0, uint256 p1, uint256 t1, uint256 p2, uint256 t2) {
        return (topPosts[0].postId, topPosts[0].total, topPosts[1].postId, topPosts[1].total, topPosts[2].postId, topPosts[2].total);
    }

    function _projectSMaxDecay(uint256 currentEpoch) internal view returns (uint256) {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) return sMax;
        uint256 elapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (elapsed > sMaxDecayMaxEpochs) elapsed = sMaxDecayMaxEpochs;
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) { decayed = (decayed * sMaxDecayRateRay) / RAY; if (decayed == 0) break; }
        uint256 leader = topPosts[0].total;
        return decayed > leader ? decayed : leader;
    }

        /// @dev Recompute weighted positions after compaction.
    ///      Each lot's position = cumulative stake of preceding lots.
    function _recomputeWeightedPositions(SideQueue storage q) internal {
        uint256 cumulative = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            if (q.lots[i].amount == 0) continue;
            q.lots[i].weightedPosition = cumulative;
            cumulative += q.lots[i].amount;
        }
    }

    function _recomputeSideTotal(SideQueue storage q) internal {
        uint256 total = 0;
        for (uint256 i = 0; i < q.lots.length; i++) { total += q.lots[i].amount; }
        q.total = total;
    }

    uint256[500] private __gap;
}
