// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {VSPToken} from "../src/VSPToken.sol";
import {Authority} from "../src/authority/Authority.sol";

contract VSPTokenTest is Test {
    VSPToken token;
    address owner = address(0xA11CE);
    address user1 = address(0xBEEF);
    address user2 = address(0xCAFE);

    function setUp() public {
        Authority auth = new Authority(owner);
        token = new VSPToken(address(auth));

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
    }

    function test_RevertWhen_NonOwnerMints() public {
        vm.prank(user1);
        vm.expectRevert("not minter");
        token.mint(user1, 1000);
    }

    function test_RevertWhen_NonOwnerBurns() public {
        vm.prank(user1);
        vm.expectRevert("not burner");
        token.burn(100);
    }

    function test_RevertWhen_BurnFromWithoutAllowance() public {
        vm.startPrank(owner);
        token.mint(user1, 1000);
        vm.stopPrank();

        vm.prank(user2);  // non-burner
        vm.expectRevert("not burner");  // or "insufficient allowance" if you add check
        token.burnFrom(user1, 300);
    }

    function testOwnerCanSetRoles() public {
        Authority auth = Authority(address(token.authority()));

        vm.prank(owner);
        auth.setMinter(user2, true);

        assertTrue(auth.isMinter(user2));
    }

    function test_RevertWhen_NonOwnerSetsRoles() public {
        Authority auth = Authority(address(token.authority()));

        vm.prank(user1);
        vm.expectRevert("AUTH: not owner");
        auth.setMinter(user2, true);
    }
}
