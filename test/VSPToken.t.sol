// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
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
        VSPToken tokenImpl = new VSPToken(address(0));
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(VSPToken.initialize, (address(auth)))
        );
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
        vm.expectRevert("not burner");
        token.burnFrom(user1, 300);
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
