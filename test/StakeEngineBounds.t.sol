// SPDX-License-Identifier: MIT
// bundle05_a: tests for stake amount caps (G-9) and setStake target cap (G-10).
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "../src/interfaces/IVSPToken.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

contract StakeEngineBoundsTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockProtocolPolicy policy;

    address alice = address(0xA11CE);

    uint256 internal CAP; // local copy of MAX_STAKE_AMOUNT
    uint256 internal constant POST_A = 1;

    function setUp() public {
        token = new MockVSP();
        policy = new MockProtocolPolicy(0);

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(StakeEngine.initialize, (address(this), address(token), address(policy)))
                )
            )
        );

        CAP = engine.MAX_STAKE_AMOUNT();

        // Fund alice with enough VSP to attempt over-cap stakes.
        token.mint(alice, CAP * 10);
        vm.prank(alice);
        token.approve(address(engine), type(uint256).max);
    }

    // ───────────────────────────────────────────────────────────────────────
    // G-9: stake() amount cap
    // ───────────────────────────────────────────────────────────────────────

    function test_constants() public {
        // Cap should be exactly 10M VSP (10_000_000 * 1e18).
        assertEq(CAP, 10_000_000 ether);
    }

    function test_stake_atCap_succeeds() public {
        // Staking exactly CAP should succeed.
        vm.prank(alice);
        engine.stake(POST_A, 0, CAP);

        (uint256 sup, uint256 cha) = engine.getPostTotals(POST_A);
        assertEq(sup, CAP);
        assertEq(cha, 0);
    }

    function test_stake_overCap_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.StakeAmountTooLarge.selector, CAP + 1, CAP));
        vm.prank(alice);
        engine.stake(POST_A, 0, CAP + 1);
    }

    function test_stake_wayOverCap_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.StakeAmountTooLarge.selector, type(uint256).max, CAP));
        vm.prank(alice);
        engine.stake(POST_A, 0, type(uint256).max);
    }

    function test_stake_belowCap_succeeds() public {
        // Sanity: normal stake amount well below the cap.
        vm.prank(alice);
        engine.stake(POST_A, 0, 100 ether);

        (uint256 sup,) = engine.getPostTotals(POST_A);
        assertEq(sup, 100 ether);
    }

    // ───────────────────────────────────────────────────────────────────────
    // G-10: setStake() target cap
    // ───────────────────────────────────────────────────────────────────────

    function test_setStake_atCap_succeeds() public {
        vm.prank(alice);
        engine.setStake(POST_A, int256(CAP));

        (uint256 sup,) = engine.getPostTotals(POST_A);
        assertEq(sup, CAP);
    }

    function test_setStake_overCap_reverts() public {
        int256 target = int256(CAP) + 1;
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.SetStakeTargetTooLarge.selector, target, CAP));
        vm.prank(alice);
        engine.setStake(POST_A, target);
    }

    function test_setStake_negativeCap_succeeds() public {
        // First stake on support so we have something to unstake from.
        vm.prank(alice);
        engine.stake(POST_A, 0, 1000 ether);

        // setStake to negative CAP magnitude: zero out support, fill challenge to CAP.
        // |target| = CAP is at the boundary; should succeed (cap is > not >=).
        vm.prank(alice);
        engine.setStake(POST_A, -int256(CAP));

        (uint256 sup, uint256 cha) = engine.getPostTotals(POST_A);
        assertEq(sup, 0);
        assertEq(cha, CAP);
    }

    function test_setStake_negativeOverCap_reverts() public {
        int256 target = -int256(CAP) - 1; // |target| = CAP + 1
        vm.expectRevert(abi.encodeWithSelector(StakeEngine.SetStakeTargetTooLarge.selector, target, CAP));
        vm.prank(alice);
        engine.setStake(POST_A, target);
    }

    function test_setStake_zero_succeeds() public {
        // Zero target should always be allowed (it withdraws everything).
        vm.prank(alice);
        engine.stake(POST_A, 0, 100 ether);
        vm.prank(alice);
        engine.setStake(POST_A, 0);

        (uint256 sup, uint256 cha) = engine.getPostTotals(POST_A);
        assertEq(sup, 0);
        assertEq(cha, 0);
    }
}
