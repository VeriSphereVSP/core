// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IVSPToken.sol";
import "./governance/StakeRatePolicy.sol";
import "./governance/GovernedUpgradeable.sol";

/// @title StakeEngine (v2)
/// @notice Manages VSP staking on posts with:
///         - Lot consolidation: one lot per user per side per post
///         - Positional weighting via governance-configurable tranches
///         - Periodic snapshots: O(N) computation at most once per period
///         - Lazy view projection: reads are always current, O(1), no gas
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
        uint256 weightedPosition; // Stake-weighted queue position (midpoint)
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
    uint256 public sMaxPostId; // Post ID that currently holds sMax (= topPosts[0].postId when non-zero)

    struct TopPost { uint256 postId; uint256 total; }
    TopPost[3] private topPosts; // Sorted descending by total; topPosts[0] is the leader

    uint256 private constant SMAX_DECAY_RATE_RAY = 995e15; // 0.995 — 0.5%/epoch decay
    uint256 private constant SMAX_DECAY_MAX_EPOCHS = 3650; // cap projection iterations

    // Manual reentrancy guard
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

    /// @notice Snapshot period length. State-changing ops trigger O(N)
    ///         computation at most once per period.
    uint256 public snapshotPeriod;

    /// @notice Number of positional tranches for reward weighting.
    ///         Earlier tranches earn higher rates. Governance-configurable.
    uint256 public numTranches;

    // ------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------

    uint256 public constant EPOCH_LENGTH = 1 days;
    uint256 public constant YEAR_LENGTH = 365 days;
    uint256 private constant RAY = 1e18;

    // sMax decay constants removed — sMax is now tracked live
    // uint256 private constant SMAX_DECAY_RATE_RAY = 999e15;
    // uint256 private constant SMAX_MAX_DECAY_EPOCHS = 3650;

    uint256 private constant DEFAULT_SNAPSHOT_PERIOD = 1 days;
    uint256 private constant DEFAULT_NUM_TRANCHES = 10;

    // ------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------

    error InvalidSide();
    error AmountZero();
    error OppositeSideStaked();
    error NotEnoughStake();
    error ZeroAddressToken();
    error InvalidTranches();
    error InvalidSnapshotPeriod();
    error NoGhostLots();

    // ------------------------------------------------------------
    // Events
    // ------------------------------------------------------------

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
    event EpochMinted(uint256 indexed postId, uint256 amount);
    event EpochBurned(uint256 indexed postId, uint256 amount);
    event SnapshotPeriodSet(uint256 oldPeriod, uint256 newPeriod);
    event NumTranchesSet(uint256 oldTranches, uint256 newTranches);
    event LotsCompacted(uint256 indexed postId, uint8 side, uint256 removed);
    event SMaxRescanned(uint256 newSMax, uint256 newSMaxPostId);

    // ------------------------------------------------------------
    // Constructor / Initializer
    // ------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) GovernedUpgradeable(trustedForwarder_) {}

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
        snapshotPeriod = DEFAULT_SNAPSHOT_PERIOD;
        numTranches = DEFAULT_NUM_TRANCHES;
    }

    // ------------------------------------------------------------
    // Governance setters
    // ------------------------------------------------------------

    function setSnapshotPeriod(uint256 newPeriod) external onlyGovernance {
        if (newPeriod == 0) revert InvalidSnapshotPeriod();
        emit SnapshotPeriodSet(snapshotPeriod, newPeriod);
        snapshotPeriod = newPeriod;
    }

    function setNumTranches(uint256 newTranches) external onlyGovernance {
        if (newTranches == 0) revert InvalidTranches();
        emit NumTranchesSet(numTranches, newTranches);
        numTranches = newTranches;
    }
    /// @notice Remove zero-amount ghost lots from a side queue.
    ///         Callable by governance to reduce snapshot gas cost on posts
    ///         that have accumulated burned-out lots over time.
    ///         Uses swap-and-pop to compact the array in O(N).
    /// @param postId The post to compact.
    /// @param side   0 = support, 1 = challenge.
    function compactLots(uint256 postId, uint8 side) external onlyGovernance nonReentrant {
        if (side > 1) revert InvalidSide();

        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];

        uint256 removed = 0;

        // Walk backwards so swap-and-pop doesn't skip elements
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
        emit LotsCompacted(postId, side, removed);
    }


    // ------------------------------------------------------------
    // Read (view — always current via projection)
    // ------------------------------------------------------------

    /// @notice Returns projected totals including unrealized epoch gains/losses.
    function getPostTotals(
        uint256 postId
    ) external view returns (uint256 support, uint256 challenge) {
        PostState storage ps = posts[postId];
        uint256 currentEpoch = _currentEpoch();
        uint256 snapshotEpoch = ps.lastSnapshotEpoch;

        uint256 storedS = ps.sides[0].total;
        uint256 storedC = ps.sides[1].total;

        // If no snapshot has been taken or no time elapsed, return stored values
        if (snapshotEpoch == 0 || currentEpoch <= snapshotEpoch) {
            return (storedS, storedC);
        }

        // Project the effect of elapsed epochs without writing state
        return _projectTotals(ps, currentEpoch);
    }

    /// @notice Returns a user's projected stake on a given post and side.
    function getUserStake(
        address user,
        uint256 postId,
        uint8 side
    ) external view returns (uint256) {
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

        // Project this lot's value
        return _projectLotValue(ps, lot, currentEpoch);
    }


    /// @notice Returns full lot info for a user's position on a post side.
    /// @return amount Current stake amount (projected)
    /// @return weightedPosition Stake-weighted queue position
    /// @return entryEpoch Epoch when user first staked
    /// @return sideTotal Total stake on this side
    /// @return tranche Which positional tranche (0=earliest/best)
    /// @return positionWeight Rate multiplier for this tranche (RAY-scaled)
    function getUserLotInfo(
        address user,
        uint256 postId,
        uint8 side
    ) external view returns (
        uint256 amount,
        uint256 weightedPosition,
        uint256 entryEpoch,
        uint256 sideTotal,
        uint256 tranche,
        uint256 positionWeight
    ) {
        if (side > 1) revert InvalidSide();

        PostState storage ps = posts[postId];
        uint256 idx = _getLotIndex(ps, user, side);
        if (idx == 0) return (0, 0, 0, 0, 0, 0);

        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount == 0) return (0, 0, 0, 0, 0, 0);

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
        tranche = 0;

        return (
            projectedAmount,
            lot.weightedPosition,
            lot.entryEpoch,
            sideTotal,
            tranche,
            positionWeight
        );
    }

    // ------------------------------------------------------------
    // Stake (state-changing)
    // ------------------------------------------------------------

    function stake(uint256 postId, uint8 side, uint256 amount) external nonReentrant {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        // Enforce single-sided positions: reject if user has stake on opposite side
        PostState storage psCheck = posts[postId];
        uint8 opposite = 1 - side;
        uint256 oppIdx = _getLotIndex(psCheck, _msgSender(), opposite);
        if (oppIdx > 0 && psCheck.sides[opposite].lots[oppIdx - 1].amount > 0) {
            revert OppositeSideStaked();
        }

        require(ERC20_TOKEN.transferFrom(_msgSender(), address(this), amount), "VSP transfer failed");

        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();

        // Initialize snapshot epoch on first interaction
        if (ps.lastSnapshotEpoch == 0) ps.lastSnapshotEpoch = epoch;

        // Trigger snapshot if period has elapsed
        _maybeSnapshot(postId, epoch);

        // Consolidate: find or create user's lot on this side
        _addOrMergeLot(postId, side, amount, _msgSender());

        emit StakeAdded(postId, _msgSender(), side, amount);
    }

    // ------------------------------------------------------------
    // Withdraw (state-changing)
    // ------------------------------------------------------------

    function withdraw(
        uint256 postId,
        uint8 side,
        uint256 amount,
        bool /* lifo - deprecated, kept for interface compat */
    ) external nonReentrant {
        if (amount == 0) revert AmountZero();
        if (side > 1) revert InvalidSide();

        PostState storage ps = posts[postId];
        uint256 epoch = _currentEpoch();

        // Trigger snapshot if period has elapsed (materializes gains/losses)
        _maybeSnapshot(postId, epoch);

        uint256 idx = _getLotIndex(ps, _msgSender(), side);
        if (idx == 0) revert NotEnoughStake();

        StakeLot storage lot = ps.sides[side].lots[idx - 1];
        if (lot.amount < amount) revert NotEnoughStake();

        // Reduce lot amount; position stays the same
        lot.amount -= amount;
        ps.sides[side].total -= amount;

        // Update sMax (may trigger rescan if this was the leader)
        uint256 TT = ps.sides[0].total + ps.sides[1].total;
        _updateSMax(postId, TT);

        require(ERC20_TOKEN.transfer(_msgSender(), amount), "VSP transfer failed");

        emit StakeWithdrawn(postId, _msgSender(), side, amount, true);
    }

    // ------------------------------------------------------------
    // Permissionless update (anyone can trigger snapshot)
    // ------------------------------------------------------------

    function updatePost(uint256 postId) external nonReentrant {
        uint256 epoch = _currentEpoch();
        _forceSnapshot(postId, epoch);
    }

    // ------------------------------------------------------------
    // Internal: Snapshot logic
    // ------------------------------------------------------------

    /// @dev Triggers snapshot only if a full period has elapsed since last one.
    function _maybeSnapshot(uint256 postId, uint256 currentEpoch) internal {
        PostState storage ps = posts[postId];
        uint256 lastEpoch = ps.lastSnapshotEpoch;

        if (lastEpoch == 0) {
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        // Check if a full snapshot period has elapsed
        uint256 periodInEpochs = snapshotPeriod / EPOCH_LENGTH;
        if (periodInEpochs == 0) periodInEpochs = 1;

        if (currentEpoch >= lastEpoch + periodInEpochs) {
            _forceSnapshot(postId, currentEpoch);
        }
    }

    /// @dev Forces the O(N) snapshot computation.
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
            ps.lastSnapshotEpoch = currentEpoch;
            return;
        }

        bool supportWins = vsNum > 0;
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);

        uint256 epochsElapsed = currentEpoch - lastEpoch;
        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / sMax;

        uint256 rMin = (ratePolicy.stakeIntRateMinRay() *
            EPOCH_LENGTH *
            epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() *
            EPOCH_LENGTH *
            epochsElapsed) / YEAR_LENGTH;

        uint256 rBase = rMin +
            ((rMax - rMin) * vRay * participationRay) /
            (RAY * RAY);

        // Apply to each side with positional weighting
        (uint256 mintS, uint256 burnS) = _applyEpochTranched(
            qs,
            supportWins,
            true,
            rBase
        );
        (uint256 mintC, uint256 burnC) = _applyEpochTranched(
            qc,
            supportWins,
            false,
            rBase
        );

        if (mintS + mintC > 0) {
            VSP_TOKEN.mint(address(this), mintS + mintC);
            emit EpochMinted(postId, mintS + mintC);
        }
        if (burnS + burnC > 0) {
            VSP_TOKEN.burn(burnS + burnC);
            emit EpochBurned(postId, burnS + burnC);
        }

        // Recompute totals
        _recomputeSideTotal(qs);
        _recomputeSideTotal(qc);
        ps.lastSnapshotEpoch = currentEpoch;

        // Update sMax
        uint256 TT = qs.total + qc.total;
        _updateSMax(postId, TT);

        emit PostUpdated(postId, currentEpoch, qs.total, qc.total);
    }

    /// @dev Applies epoch gains/losses with positional tranche weighting.
    ///      Earlier lots (lower weightedPosition) get higher rate multipliers.
    function _applyEpochTranched(
        SideQueue storage q,
        bool supportWins,
        bool isSupportSide,
        uint256 rBase
    ) internal returns (uint256 minted, uint256 burned) {
        if (q.total == 0 || rBase == 0 || sMax == 0) return (0, 0);

        bool aligned = (supportWins && isSupportSide) ||
            (!supportWins && !isSupportSide);

        uint256 T = q.total;
        uint256 nT = numTranches;

        for (uint256 i = 0; i < q.lots.length; i++) {
            StakeLot storage lot = q.lots[i];
            if (lot.amount == 0) continue;

            // Determine which tranche this lot falls in based on position
            // Tranche 0 = earliest (highest reward), tranche nT-1 = latest
            uint256 tranche = (lot.weightedPosition * nT) / T;
            if (tranche >= nT) tranche = nT - 1;

            // Position weight: tranche 0 gets weight nT/nT = 1.0,
            // tranche nT-1 gets weight 1/nT
            uint256 positionWeight = ((nT - tranche) * RAY) / nT;

            // Effective rate for this lot
            uint256 rLot = (rBase * positionWeight) / RAY;

            uint256 delta = (lot.amount * rLot) / RAY;
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

    // ------------------------------------------------------------
    // Internal: Lot management (consolidation)
    // ------------------------------------------------------------

    function _addOrMergeLot(
        uint256 postId,
        uint8 side,
        uint256 amount,
        address staker
    ) internal {
        PostState storage ps = posts[postId];
        SideQueue storage q = ps.sides[side];

        uint256 idx = _getLotIndex(ps, staker, side);

        if (idx != 0) {
            // Merge into existing lot with stake-weighted position
            StakeLot storage existing = q.lots[idx - 1];
            uint256 oldAmount = existing.amount;
            uint256 newEntryPosition = q.total; // Back of the queue

            // Stake-weighted average position
            existing.weightedPosition =
                (existing.weightedPosition *
                    oldAmount +
                    newEntryPosition *
                    amount) /
                (oldAmount + amount);

            existing.amount = oldAmount + amount;
        } else {
            // Create new lot at back of queue
            uint256 newIdx = q.lots.length;
            q.lots.push(
                StakeLot({
                    staker: staker,
                    amount: amount,
                    side: side,
                    weightedPosition: q.total, // Back of queue
                    entryEpoch: _currentEpoch()
                })
            );
            _setLotIndex(ps, staker, side, newIdx + 1);
        }

        q.total += amount;

        // Update sMax
        uint256 TT = ps.sides[0].total + ps.sides[1].total;
        _updateSMax(postId, TT);
    }

    function _getLotIndex(
        PostState storage ps,
        address user,
        uint8 side
    ) internal view returns (uint256) {
        if (side == 0) return ps.lotIndex0[user];
        return ps.lotIndex1[user];
    }

    function _setLotIndex(
        PostState storage ps,
        address user,
        uint8 side,
        uint256 idxPlusOne
    ) internal {
        if (side == 0) {
            ps.lotIndex0[user] = idxPlusOne;
        } else {
            ps.lotIndex1[user] = idxPlusOne;
        }
    }

    // ------------------------------------------------------------
    // Internal: View projection (pure computation, no state changes)
    // ------------------------------------------------------------

    /// @dev Projects what totals would be if snapshot ran right now.
    function _projectTotals(
        PostState storage ps,
        uint256 currentEpoch
    ) internal view returns (uint256 projS, uint256 projC) {
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

        // Project sMax decay
        uint256 projSMax = _projectSMaxDecay(currentEpoch);
        if (projSMax == 0) return (A, D);

        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / projSMax;

        uint256 rMin = (ratePolicy.stakeIntRateMinRay() *
            EPOCH_LENGTH *
            epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() *
            EPOCH_LENGTH *
            epochsElapsed) / YEAR_LENGTH;

        uint256 rBase = rMin +
            ((rMax - rMin) * vRay * participationRay) /
            (RAY * RAY);

        // Project each side
        projS = _projectSideTotal(qs, supportWins, true, rBase);
        projC = _projectSideTotal(qc, supportWins, false, rBase);
    }

    function _projectSideTotal(
        SideQueue storage q,
        bool supportWins,
        bool isSupportSide,
        uint256 rBase
    ) internal view returns (uint256 total) {
        if (q.total == 0 || rBase == 0) return q.total;
        bool aligned = (supportWins && isSupportSide) ||
            (!supportWins && !isSupportSide);
        uint256 T = q.total;
        uint256 budget = (T * rBase) / RAY;

        // Normalize: totalWeightedStake across all lots
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

        // Distribute budget; accumulate resulting side total
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

    function _projectLotValue(
        PostState storage ps,
        StakeLot storage lot,
        uint256 currentEpoch
    ) internal view returns (uint256) {
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
        bool aligned = (supportWins && isSupportSide) ||
            (!supportWins && !isSupportSide);
        uint256 absVS = uint256(vsNum > 0 ? vsNum : -vsNum);
        uint256 epochsElapsed = currentEpoch - ps.lastSnapshotEpoch;
        uint256 projSMax = _projectSMaxDecay(currentEpoch);
        if (projSMax == 0) return lot.amount;

        uint256 vRay = (absVS * RAY) / T;
        uint256 participationRay = (T * RAY) / projSMax;
        if (participationRay > RAY) participationRay = RAY;
        uint256 rMin = (ratePolicy.stakeIntRateMinRay() *
            EPOCH_LENGTH *
            epochsElapsed) / YEAR_LENGTH;
        uint256 rMax = (ratePolicy.stakeIntRateMaxRay() *
            EPOCH_LENGTH *
            epochsElapsed) / YEAR_LENGTH;
        uint256 rBase = rMin +
            ((rMax - rMin) * vRay * participationRay) /
            (RAY * RAY);

        // Budget to distribute across this side = sideTotal × rBase
        SideQueue storage mySide = isSupportSide ? qs : qc;
        uint256 sideTotal = mySide.total;
        if (sideTotal == 0 || rBase == 0) return lot.amount;
        uint256 budget = (sideTotal * rBase) / RAY;

        // Compute totalWeightedStake across all lots on this side (for normalization)
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

        // This lot's share of the budget
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

    function _currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_LENGTH;
    }

    /// @dev Update sMax after a post's total changes. Maintains topPosts[0..2]
    ///      sorted descending. On leader shrink, promotes #2 if possible; otherwise
    ///      decays from current sMax. O(1) per call.
    function _updateSMax(uint256 postId, uint256 postTotal) internal {
        // Find if postId is already tracked and at what index
        uint256 slot = type(uint256).max;
        for (uint256 i = 0; i < 3; i++) {
            if (topPosts[i].postId == postId && topPosts[i].total > 0) { slot = i; break; }
        }

        if (slot != type(uint256).max) {
            // Post is tracked: update its total
            topPosts[slot].total = postTotal;
            // If it shrank below a neighbor, bubble down; if it grew, bubble up
            while (slot > 0 && topPosts[slot].total > topPosts[slot - 1].total) {
                TopPost memory tmp = topPosts[slot];
                topPosts[slot] = topPosts[slot - 1];
                topPosts[slot - 1] = tmp;
                slot--;
            }
            while (slot < 2 && topPosts[slot].total < topPosts[slot + 1].total) {
                TopPost memory tmp = topPosts[slot];
                topPosts[slot] = topPosts[slot + 1];
                topPosts[slot + 1] = tmp;
                slot++;
            }
        } else {
            // Post not tracked: try to insert if larger than the smallest tracked
            // Find insertion point (topPosts is sorted desc)
            for (uint256 i = 0; i < 3; i++) {
                if (postTotal > topPosts[i].total) {
                    // Shift right and insert
                    for (uint256 j = 2; j > i; j--) { topPosts[j] = topPosts[j - 1]; }
                    topPosts[i] = TopPost(postId, postTotal);
                    break;
                }
            }
        }

        // Evict stale or empty entries that crept in: zero out zero-total slots
        for (uint256 i = 0; i < 3; i++) {
            if (topPosts[i].total == 0) topPosts[i] = TopPost(0, 0);
        }

        // Update sMax from top-1. If top-1 is 0, decay from previous sMax instead.
        uint256 leaderTotal = topPosts[0].total;
        uint256 currentEpoch = _currentEpoch();

        if (leaderTotal > 0) {
            if (leaderTotal >= sMax) {
                // Leader at least as large as previous sMax: lock in, reset decay clock
                sMax = leaderTotal;
                sMaxLastUpdatedEpoch = currentEpoch;
            } else {
                // Leader is below previous sMax: apply decay from previous sMax,
                // but never below leaderTotal (which is our firm floor)
                uint256 decayed = _applySMaxDecay(currentEpoch);
                sMax = decayed > leaderTotal ? decayed : leaderTotal;
                // sMaxLastUpdatedEpoch already updated inside _applySMaxDecay
            }
            sMaxPostId = topPosts[0].postId;
        } else {
            // No tracked leader: decay pure form
            sMax = _applySMaxDecay(currentEpoch);
            // Keep sMaxPostId as informational; it may now be stale
        }
    }

    /// @dev Apply exponential decay to sMax based on epochs since last update.
    ///      Writes sMaxLastUpdatedEpoch. Returns new sMax value.
    function _applySMaxDecay(uint256 currentEpoch) internal returns (uint256) {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) {
            sMaxLastUpdatedEpoch = currentEpoch;
            return sMax;
        }
        uint256 elapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (elapsed > SMAX_DECAY_MAX_EPOCHS) elapsed = SMAX_DECAY_MAX_EPOCHS;
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) {
            decayed = (decayed * SMAX_DECAY_RATE_RAY) / RAY;
            if (decayed == 0) break;
        }
        sMax = decayed;
        sMaxLastUpdatedEpoch = currentEpoch;
        return decayed;
    }

    /// @notice Governance: force a rebuild of the top-3 sMax tracker.
    ///         Use when sMax diverges from reality (upgrade state, griefing recovery).
    ///         Scans provided post IDs and populates topPosts[0..2] with the largest.
    function rescanSMax(uint256[] calldata postIds) external onlyGovernance {
        // Reset top-3
        for (uint256 i = 0; i < 3; i++) topPosts[i] = TopPost(0, 0);
        // Insert each post via the standard update path so sort is maintained
        for (uint256 i = 0; i < postIds.length; i++) {
            uint256 pid = postIds[i];
            // no nextPostId check — PostState.sides[].lots.length handles unknown pids
            PostState storage ps = posts[pid];
            uint256 total = ps.sides[0].total + ps.sides[1].total;
            if (total == 0) continue;
            _updateSMax(pid, total);
        }
        emit SMaxRescanned(topPosts[0].total, topPosts[0].postId);
    }

    /// @notice View the current top-3 posts by total stake (for off-chain monitoring).
    function getTopPosts() external view returns (
        uint256 p0, uint256 t0,
        uint256 p1, uint256 t1,
        uint256 p2, uint256 t2
    ) {
        return (
            topPosts[0].postId, topPosts[0].total,
            topPosts[1].postId, topPosts[1].total,
            topPosts[2].postId, topPosts[2].total
        );
    }

    /// @dev View-only sMax projection — applies decay from last update without writing.
    ///      Result is never below topPosts[0].total (firm floor from tracked leader).
    function _projectSMaxDecay(
        uint256 currentEpoch
    ) internal view returns (uint256) {
        if (sMax == 0 || currentEpoch <= sMaxLastUpdatedEpoch) return sMax;
        uint256 elapsed = currentEpoch - sMaxLastUpdatedEpoch;
        if (elapsed > SMAX_DECAY_MAX_EPOCHS) elapsed = SMAX_DECAY_MAX_EPOCHS;
        uint256 decayed = sMax;
        for (uint256 i = 0; i < elapsed; i++) {
            decayed = (decayed * SMAX_DECAY_RATE_RAY) / RAY;
            if (decayed == 0) break;
        }
        uint256 leader = topPosts[0].total;
        return decayed > leader ? decayed : leader;
    }

    function _recomputeSideTotal(SideQueue storage q) internal {
        uint256 total = 0;
        for (uint256 i = 0; i < q.lots.length; i++) {
            total += q.lots[i].amount;
        }
        q.total = total;
    }

    uint256[36] private __gap; // reduced by 8: _reentrancyStatus + sMaxPostId + topPosts[3] (6 slots)
}
