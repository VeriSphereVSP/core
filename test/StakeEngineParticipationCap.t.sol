// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// @title Participation-cap regression (APR must never exceed rMax)
/// @notice Reproduces the bug where `participationRay = T / sMax` was not
///         clamped to 1.0 in two of the three rate computations
///         (_forceSnapshot, _projectTotals), letting per-epoch growth — and the
///         displayed APR — exceed the rMax cap.
///
/// Trigger: topPosts tracks only the top 3 posts. An untracked post (rank 4+)
/// whose total exceeds a STALE sMax produces participationRay > 1.0. We create
/// that state by filling topPosts with three big posts, staking a smaller
/// untracked fourth, then withdrawing the big three below the fourth — leaving
/// sMax stale and far below the fourth post's total.
contract StakeEngineParticipationCapTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockProtocolPolicy policy;

    function setUp() public {
        token = new MockVSP();
        policy = new MockProtocolPolicy(0); // rMin=0, rMax=50% APR

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(token), address(policy)))
                )
            )
        );
        token.mint(address(this), 1e36);
        token.approve(address(engine), type(uint256).max);
    }

    uint256 constant BIG = 100e18;
    uint256 constant SMALL = 50e18;
    uint256 constant RAY = 1e18;

    /// Build the stale-sMax state: post #4 (untracked) ends up far larger than sMax.
    function _staleSMaxWithUntrackedLeader() internal {
        engine.stake(1, 0, BIG);
        engine.stake(2, 0, BIG);
        engine.stake(3, 0, BIG); // topPosts = {1,2,3}, sMax = 100e18
        engine.stake(4, 0, SMALL); // rank 4 — NOT inserted into topPosts
        // shrink the tracked three below post #4 → sMax goes stale at 1e18
        engine.withdraw(1, 0, BIG - 1e18, false);
        engine.withdraw(2, 0, BIG - 1e18, false);
        engine.withdraw(3, 0, BIG - 1e18, false);
    }

    function _rMaxPerEpoch() internal view returns (uint256) {
        return (policy.stakeIntRateMaxRay() * engine.EPOCH_LENGTH()) / engine.YEAR_LENGTH();
    }

    /// VIEW path (_projectTotals): the projected total — what the UI shows as
    /// growth/APR — must not grow faster than rMax in one epoch.
    function test_ViewProjectionRespectsRMaxCap() public {
        _staleSMaxWithUntrackedLeader();
        vm.warp(block.timestamp + 1 days + 1); // advance one epoch so the view projects

        (uint256 projS,) = engine.getPostTotals(4);
        // winning (support) side may grow by at most rMax per epoch
        uint256 cap = SMALL + (SMALL * _rMaxPerEpoch()) / RAY + 2; // +2 wei rounding slack
        assertLe(projS, cap, "VIEW: projected growth exceeds rMax (participationRay not clamped)");
    }

    /// MATERIALIZED path (_forceSnapshot): triggering a snapshot must not MINT
    /// growth above rMax, even when sMax is stale below the post's total.
    function test_MaterializedGrowthRespectsRMaxCap() public {
        _staleSMaxWithUntrackedLeader();
        vm.warp(block.timestamp + 1 days + 1);

        // a 1-wei stake triggers _forceSnapshot on post #4 using the stale sMax
        engine.stake(4, 0, 1);

        (uint256 matS,) = engine.getPostTotals(4); // now materialized (epoch == snapshot)
        uint256 cap = SMALL + (SMALL * _rMaxPerEpoch()) / RAY + 1 /*the wei*/ + 2;
        assertLe(matS, cap, "MATERIALIZED: minted growth exceeds rMax (participationRay not clamped)");
    }

    /// Sanity: a normal sole-leader post (T == sMax) is unaffected by the fix —
    /// it grows at up to rMax, never artificially throttled below it.
    function test_SoleLeaderStillGrowsUpToRMax() public {
        engine.stake(7, 0, 100e18); // sole leader: sMax == T
        vm.warp(block.timestamp + 1 days + 1);
        (uint256 projS,) = engine.getPostTotals(7);
        assertGe(projS, 100e18, "sole leader should not shrink");
        uint256 cap = 100e18 + (100e18 * _rMaxPerEpoch()) / RAY + 2;
        assertLe(projS, cap, "sole leader should still be bounded by rMax");
    }
}
