// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "../src/governance/ProtocolPolicy.sol";

contract ProtocolPolicyBoundsTest is Test {
    address timelock;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        TimelockController tl = new TimelockController(0, proposers, executors, address(this));
        timelock = address(tl);
    }

    function _newPolicy() internal returns (ProtocolPolicy) {
        return new ProtocolPolicy(timelock, 0, 1e18, 1e18, 0);
    }

    function test_constants() public {
        ProtocolPolicy p = _newPolicy();
        assertEq(p.MAX_RATE_MIN_RAY(), 1e18);
        assertEq(p.MAX_RATE_MAX_RAY(), 5e18);
        assertEq(p.MIN_POSTING_FEE_WEI(), 1e15);
        assertEq(p.MAX_POSTING_FEE_WEI(), 100e18);
        assertEq(p.MAX_MIN_STAKE_WEI(), 10000e18);
    }

    function test_ctor_acceptsBounds() public {
        ProtocolPolicy p = new ProtocolPolicy(timelock, 0, 5e18, 100e18, 10000e18);
        assertEq(p.stakeIntRateMaxRay(), 5e18);
        assertEq(p.postingFeeVSP(), 100e18);
        assertEq(p.minTotalStakeVSP(), 10000e18);
    }

    function test_ctor_rejectsRateMinAboveCap() public {
        vm.expectRevert(ProtocolPolicy.RateOutOfBounds.selector);
        new ProtocolPolicy(timelock, 1e18 + 1, 5e18, 1e18, 0);
    }

    function test_ctor_rejectsRateMaxAboveCap() public {
        vm.expectRevert(ProtocolPolicy.RateOutOfBounds.selector);
        new ProtocolPolicy(timelock, 0, 5e18 + 1, 1e18, 0);
    }

    function test_ctor_rejectsRateMinAboveMax() public {
        vm.expectRevert(ProtocolPolicy.RateOutOfBounds.selector);
        new ProtocolPolicy(timelock, 5e17, 1e17, 1e18, 0);
    }

    function test_ctor_rejectsFeeBelowMin() public {
        vm.expectRevert(ProtocolPolicy.FeeOutOfBounds.selector);
        new ProtocolPolicy(timelock, 0, 1e18, 1e15 - 1, 0);
    }

    function test_ctor_rejectsFeeAboveMax() public {
        vm.expectRevert(ProtocolPolicy.FeeOutOfBounds.selector);
        new ProtocolPolicy(timelock, 0, 1e18, 100e18 + 1, 0);
    }

    function test_ctor_rejectsMinStakeAboveMax() public {
        vm.expectRevert(ProtocolPolicy.MinStakeOutOfBounds.selector);
        new ProtocolPolicy(timelock, 0, 1e18, 1e18, 10000e18 + 1);
    }

    function test_setRates_onlyTimelock() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(address(0xCAFE));
        vm.expectRevert(ProtocolPolicy.NotTimelock.selector);
        p.setRates(0, 1e18);
    }

    function test_setRates_atCap() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(timelock);
        p.setRates(1e18, 5e18);
        assertEq(p.stakeIntRateMaxRay(), 5e18);
    }

    function test_setRates_rejectsAboveCap() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(timelock);
        vm.expectRevert(ProtocolPolicy.RateOutOfBounds.selector);
        p.setRates(1e18 + 1, 5e18);
    }

    function test_setPostingFee_atBounds() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(timelock);
        p.setPostingFee(1e15);
        assertEq(p.postingFeeVSP(), 1e15);
        vm.prank(timelock);
        p.setPostingFee(100e18);
        assertEq(p.postingFeeVSP(), 100e18);
    }

    function test_setPostingFee_rejectsOutOfBounds() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(timelock);
        vm.expectRevert(ProtocolPolicy.FeeOutOfBounds.selector);
        p.setPostingFee(1e15 - 1);
        vm.prank(timelock);
        vm.expectRevert(ProtocolPolicy.FeeOutOfBounds.selector);
        p.setPostingFee(100e18 + 1);
    }

    function test_setMinTotalStake_atMax() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(timelock);
        p.setMinTotalStake(10000e18);
        assertEq(p.minTotalStakeVSP(), 10000e18);
    }

    function test_setMinTotalStake_rejectsAboveMax() public {
        ProtocolPolicy p = _newPolicy();
        vm.prank(timelock);
        vm.expectRevert(ProtocolPolicy.MinStakeOutOfBounds.selector);
        p.setMinTotalStake(10000e18 + 1);
    }

    function test_isActive() public {
        ProtocolPolicy p = new ProtocolPolicy(timelock, 0, 1e18, 1e18, 5e18);
        assertFalse(p.isActive(5e18 - 1));
        assertTrue(p.isActive(5e18));
    }
}
