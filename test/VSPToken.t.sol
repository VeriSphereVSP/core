// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
// patch_bundle10_5_part2a_timecap: Vm.Log type for MintExecuted event assertion
import {Vm} from "forge-std/Vm.sol";
import {VSPToken} from "../src/VSPToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Authority} from "../src/authority/Authority.sol";

contract VSPTokenTest is Test {
    VSPToken token;
    Authority auth;
    address owner = address(0xA11CE);
    address user1 = address(0xBEEF);
    address user2 = address(0xCAFE);

    function setUp() public {
        auth = new Authority(owner);
        // patch_bundle10_5_part2a_timecap: 4-arg constructor.
        // inception = test start (block.timestamp), supply day-0 = 1000 VSP,
        // growth = 5x/year (5e18 UD60x18). Forwarder address(0) as before.
        // patch_bundle10_5_part2a_stakeengine_exempt: 5-arg ctor (added stakeEngine_),
        // and growth rate 5e18 → 10e18 (cap relaxes 2x faster per year).
        VSPToken tokenImpl = new VSPToken(address(0), block.timestamp, 1000 * 1e18, 10 * 1e18, address(0xDEEF));
        ERC1967Proxy tokenProxy =
            new ERC1967Proxy(address(tokenImpl), abi.encodeCall(VSPToken.initialize, (address(auth))));
        token = VSPToken(address(tokenProxy));

        assertEq(auth.owner(), owner);
        assertTrue(auth.isMinter(owner));
        assertTrue(auth.isBurner(owner));
    }

    function testMintAsOwner() public {
        vm.prank(owner);
        token.mint(user1, 1000);
        assertEq(token.balanceOf(user1), 1000);
    }

    function testBurnAsOwner() public {
        vm.startPrank(owner);
        token.mint(owner, 2000);
        token.burn(500);
        vm.stopPrank();
        assertEq(token.balanceOf(owner), 1500);
    }

    function testBurnFromWithAllowance() public {
        vm.prank(owner);
        token.mint(user1, 1000);

        vm.prank(user1);
        token.approve(owner, 400);

        vm.prank(owner);
        token.burnFrom(user1, 300);

        assertEq(token.balanceOf(user1), 700);
        // Allowance should be reduced
        assertEq(token.allowance(user1, owner), 100);
    }

    function test_RevertWhen_BurnFromWithoutAllowance() public {
        vm.prank(owner);
        token.mint(user1, 1000);

        // owner has burner role but no allowance from user1
        vm.prank(owner);
        vm.expectRevert(); // ERC20InsufficientAllowance
        token.burnFrom(user1, 300);
    }

    function test_RevertWhen_BurnFromInsufficientAllowance() public {
        vm.prank(owner);
        token.mint(user1, 1000);

        vm.prank(user1);
        token.approve(owner, 100);

        vm.prank(owner);
        vm.expectRevert(); // ERC20InsufficientAllowance
        token.burnFrom(user1, 300);
    }

    function test_RevertWhen_BurnFromNonBurner() public {
        vm.prank(owner);
        token.mint(user1, 1000);

        vm.prank(user1);
        token.approve(user2, 500);

        // user2 has allowance but NOT burner role
        vm.prank(user2);
        vm.expectRevert(VSPToken.NotBurner.selector);
        token.burnFrom(user1, 300);
    }

    function test_RevertWhen_NonOwnerMints() public {
        vm.prank(user1);
        vm.expectRevert(VSPToken.NotMinter.selector);
        token.mint(user1, 1000);
    }

    function test_RevertWhen_NonOwnerBurns() public {
        vm.prank(user1);
        vm.expectRevert(VSPToken.NotBurner.selector);
        token.burn(100);
    }

    // -------- Bundle 10.5 Part 2a: time-based supply-cap tests --------
    // patch_bundle10_5_part2a_timecap. Replaces the Part-1 per-call/total-cap tests.

    function testGrowthConstantsExposed() public view {
        // Immutable getters exist and return the constructor values.
        assertEq(token.INCEPTION_SUPPLY(), 1000 * 1e18);
        // patch_bundle10_5_part2a_stakeengine_exempt: growth rate is now 10x/year.
        assertEq(token.GROWTH_BASE_PER_YEAR(), 10 * 1e18);
        assertEq(token.SECONDS_PER_YEAR(), 365 * 86400);
        // INCEPTION_TIMESTAMP was set to block.timestamp at deploy.
        assertEq(token.INCEPTION_TIMESTAMP(), block.timestamp);
    }

    function testMaxAllowedSupplyAtInception() public view {
        // At year 0, cap == INCEPTION_SUPPLY (1000 VSP).
        assertEq(token.maxAllowedSupply(), 1000 * 1e18);
    }

    function testMintAtTimeWindowCap() public {
        // Minting exactly up to the day-0 cap succeeds. Current
        // totalSupply is 0 in this fixture, so cap headroom == 1000 VSP.
        vm.prank(owner);
        token.mint(user1, 1000 * 1e18);
        assertEq(token.totalSupply(), 1000 * 1e18);
        assertEq(token.balanceOf(user1), 1000 * 1e18);
    }

    function test_RevertWhen_MintExceedsTimeWindowCap() public {
        // 1000 VSP + 1 wei at year 0 exceeds the cap and reverts with
        // structured args (totalSupplyAfter, maxAllowedNow).
        uint256 amount = (1000 * 1e18) + 1;
        uint256 maxNow = token.maxAllowedSupply();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VSPToken.MintExceedsTimeWindowCap.selector, amount, maxNow));
        token.mint(user1, amount);
    }

    function testCapAccumulatesOverTime() public {
        // patch_bundle10_5_part2a_stakeengine_exempt: growth is now 10x/yr.
        // After warping forward one year, the cap should be ~10x the
        // day-0 value (1000 -> ~10000 VSP). Tolerance for UD60x18 pow.
        vm.warp(block.timestamp + 365 days);
        uint256 cap = token.maxAllowedSupply();
        uint256 expected = 10000 * 1e18;
        uint256 tol = expected / 1000; // 0.1%
        assertApproxEqAbs(cap, expected, tol);
        // And a mint that was impossible at year 0 (e.g. 8000 VSP)
        // now succeeds (well within the 10000 VSP cap).
        vm.prank(owner);
        token.mint(user1, 8000 * 1e18);
        assertEq(token.totalSupply(), 8000 * 1e18);
    }

    function testGrowthRateScalingMath() public {
        // patch_bundle10_5_part2a_stakeengine_exempt: two-year warp: cap ~= 1000 * 10^2
        // = 100000 VSP under the 10x/yr growth rate.
        vm.warp(block.timestamp + 2 * 365 days);
        uint256 cap = token.maxAllowedSupply();
        uint256 expected = 100000 * 1e18;
        uint256 tol = expected / 1000; // 0.1%
        assertApproxEqAbs(cap, expected, tol);
    }

    function testStakeEngineImmutableExposed() public view {
        // patch_bundle10_5_part2a_stakeengine_exempt: the exempt-from-cap address getter.
        assertEq(token.STAKE_ENGINE_ADDRESS(), address(0xDEEF));
    }

    function testStakeEngineExemptFromCap() public {
        // patch_bundle10_5_part2a_stakeengine_exempt: STAKE_ENGINE_ADDRESS can mint above
        // the cap. Fill supply to the cap via a capped minter, then
        // have the exempt address mint another 5000 VSP — which would
        // revert for any capped minter.
        address engine = token.STAKE_ENGINE_ADDRESS();
        vm.prank(owner);
        auth.setMinter(engine, true);

        vm.prank(owner);
        token.mint(user1, 1000 * 1e18);
        assertEq(token.totalSupply(), 1000 * 1e18);
        assertEq(token.maxAllowedSupply(), 1000 * 1e18);

        vm.prank(engine);
        token.mint(user2, 5000 * 1e18);
        assertEq(token.totalSupply(), 6000 * 1e18);
        assertEq(token.balanceOf(user2), 5000 * 1e18);
    }

    function test_RevertWhen_NonExemptMinterAtCappedAfterEngineMint() public {
        // patch_bundle10_5_part2a_stakeengine_exempt: after STAKE_ENGINE mints freely past
        // the cap, capped minters remain bound — supplyAfter > maxAllowed
        // still reverts for non-exempt callers.
        address engine = token.STAKE_ENGINE_ADDRESS();
        vm.prank(owner);
        auth.setMinter(engine, true);
        vm.prank(engine);
        token.mint(user1, 5000 * 1e18);

        uint256 maxNow = token.maxAllowedSupply();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(VSPToken.MintExceedsTimeWindowCap.selector, (5000 * 1e18) + 1, maxNow));
        token.mint(user2, 1);
    }

    function testMintEmitsMintExecuted() public {
        // Successful mint emits MintExecuted with the post-supply and
        // the cap. We check the event topic/args loosely (amount + to).
        vm.recordLogs();
        vm.prank(owner);
        token.mint(user1, 500 * 1e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found = false;
        bytes32 sig = keccak256("MintExecuted(address,uint256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == sig) {
                found = true;
                break;
            }
        }
        assertTrue(found, "MintExecuted not emitted");
    }

    // -------- Authority two-step ownership tests --------

    function testTwoStepOwnership() public {
        vm.prank(owner);
        auth.proposeOwner(user1);
        assertEq(auth.pendingOwner(), user1);

        // user1 accepts
        vm.prank(user1);
        auth.acceptOwner();
        assertEq(auth.owner(), user1);
        assertEq(auth.pendingOwner(), address(0));
    }

    function test_RevertWhen_NonOwnerProposes() public {
        vm.prank(user1);
        vm.expectRevert(Authority.NotOwner.selector);
        auth.proposeOwner(user2);
    }

    function test_RevertWhen_WrongAddressAccepts() public {
        vm.prank(owner);
        auth.proposeOwner(user1);

        vm.prank(user2);
        vm.expectRevert(Authority.NotPendingOwner.selector);
        auth.acceptOwner();
    }

    function test_RevertWhen_ProposeZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Authority.ZeroAddress.selector);
        auth.proposeOwner(address(0));
    }

    function testOwnerCanSetRoles() public {
        vm.prank(owner);
        auth.setMinter(user2, true);
        assertTrue(auth.isMinter(user2));
    }

    function test_RevertWhen_NonOwnerSetsRoles() public {
        vm.prank(user1);
        vm.expectRevert(Authority.NotOwner.selector);
        auth.setMinter(user2, true);
    }
}
