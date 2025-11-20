// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/VSPToken.sol";

contract VSPTokenTest is Test {
    VSPToken token;
    address owner = address(0x1);
    address alice = address(0x2);

    function setUp() public {
        vm.prank(owner);
        token = new VSPToken(owner);
    }

    function testMint() public {
        vm.prank(owner);
        token.mint(alice, 1000e18);

        assertEq(token.balanceOf(alice), 1000e18);
    }
}

