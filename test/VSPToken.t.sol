// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {VSPToken} from "../src/VSPToken.sol";
import {Authority} from "../src/authority/Authority.sol";

contract VSPTokenTest is Test {
    VSPToken token;
    Authority auth;

    address owner = address(0xA11CE);
    address user1 = address(0xBEEF);
    address user2 = address(0xCAFE);

    function setUp() public {
        token = new VSPToken(owner);
        auth = Authority(address(token.authority()));

        vm.startPrank(owner);
        auth.setMinter(owner, true);
        auth.setBurner(owner, true);
        token.setIdleDecayRate(0); // disable decay for deterministic defaults
        vm.stopPrank();
    }

    // ------------------------------------------------------------
    // Mint Tests
    // ------------------------------------------------------------

    function testMintAsOwner() public {
        vm.startPrank(owner);
        token.mint(user1, 1000);
        vm.stopPrank();

        assertEq(token.balanceOf(user1), 1000);
    }

    function test_RevertWhen_NonOwnerMints() public {
        vm.prank(user1);
        vm.expectRevert("VSP: not minter");
        token.mint(user1, 1000);
    }

    function testMintAppliesDecay() public {
        vm.startPrank(owner);
        token.setIdleDecayRate(1000); // 10%
        vm.stopPrank();

        // First mint
        vm.prank(owner);
        token.mint(user1, 1000);

        // Idle for a year
        skip(365 days);

        // Mint again — triggers decay
        vm.prank(owner);
        token.mint(user1, 500);

        // Before mint:
        // balance = 1000
        // decay = 10% = 100
        //
        // After decay, 900
        // Mint +500 → 1400
        assertEq(token.balanceOf(user1), 1400);
    }

    // ------------------------------------------------------------
    // Burn Tests
    // ------------------------------------------------------------

    function testBurnAsOwner() public {
        vm.startPrank(owner);
        token.mint(owner, 2000);
        token.burn(500);
        vm.stopPrank();

        assertEq(token.balanceOf(owner), 1500);
    }

    function test_RevertWhen_NonOwnerBurns() public {
        vm.prank(user1);
        vm.expectRevert("VSP: not burner");
        token.burn(100);
    }

    function testBurnFrom() public {
        // Owner mints tokens to user1
        vm.startPrank(owner);
        token.mint(user1, 500);
        vm.stopPrank();

        // user1 must approve the owner (burner) to burn on their behalf
        vm.prank(user1);
        token.approve(owner, 300);

        // owner now calls burnFrom()
        vm.prank(owner);
        token.burnFrom(user1, 300);

        assertEq(token.balanceOf(user1), 200);
    }

    function test_RevertWhen_BurnFromWithoutAllowance() public {
        vm.startPrank(owner);
        token.mint(user1, 1000);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert();
        token.burnFrom(user1, 300);
    }

    // ------------------------------------------------------------
    // Role Tests
    // ------------------------------------------------------------

    function testOwnerCanSetRoles() public {
        vm.startPrank(owner);
        auth.setMinter(user1, true);
        auth.setBurner(user1, true);
        vm.stopPrank();

        assertTrue(auth.isMinter(user1));
        assertTrue(auth.isBurner(user1));
    }

    function test_RevertWhen_NonOwnerSetsRoles() public {
        vm.prank(user1);
        vm.expectRevert("AUTH: not owner");
        auth.setMinter(user1, true);
    }

    // ------------------------------------------------------------
    // Idle Decay Tests
    // ------------------------------------------------------------

    function testIdleDecayNoEffectAtZeroRate() public {
        vm.startPrank(owner);
        token.mint(user1, 1000);
        vm.warp(block.timestamp + 365 days);

        uint256 before = token.balanceOf(user1);
        token.applyIdleDecay(user1);
        uint256 afterBal = token.balanceOf(user1);

        vm.stopPrank();

        assertEq(before, afterBal);
    }

    function testIdleDecayAppliesCorrectly() public {
        vm.startPrank(owner);
        token.setIdleDecayRate(1000); // 10%, valid
        vm.stopPrank();

        vm.prank(owner);
        token.mint(user1, 1000);

        // Advance time 1 year
        skip(365 days);

        vm.prank(owner);
        uint256 decayed = token.applyIdleDecay(user1);

        // Expected decay = 10% = 100
        assertEq(decayed, 100);
        assertEq(token.balanceOf(user1), 900);
    }

    function testIdleDecayUpdatesLastActivity() public {
        vm.startPrank(owner);
        token.mint(user1, 1000);

        uint256 start = block.timestamp;

        vm.warp(start + 100);
        token.applyIdleDecay(user1);

        uint256 newTime = token.lastActivity(user1);
        vm.stopPrank();

        assertEq(newTime, start + 100);
    }
}

