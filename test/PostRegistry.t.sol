// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PostRegistry.sol";

contract PostRegistryTest is Test {
    PostRegistry registry;

    function setUp() public {
        registry = new PostRegistry();
    }

    function testCreateStandalonePost() public {
        uint256 id = registry.createPost("Hello world", 0);

        (address creator, uint256 timestamp, string memory text, int256 targetPostId) = registry.getPost(id);

        assertEq(creator, address(this));
        assertEq(text, "Hello world");
        assertEq(targetPostId, 0);
        assertTrue(timestamp > 0);
    }

    function testCreateSupportLink() public {
        uint256 id = registry.createPost("Link", 5);
        (,,, int256 target) = registry.getPost(id);

        assertEq(target, 5);
    }

    function testCreateChallengeLink() public {
        uint256 id = registry.createPost("Nope", -3);
        (,,, int256 target) = registry.getPost(id);

        assertEq(target, -3);
    }

    // --- Reverts ---

    function test_RevertWhen_EmptyText() public {
        vm.expectRevert(PostRegistry.EmptyText.selector);
        registry.createPost("", 0);
    }

    function test_RevertWhen_InvalidPostId() public {
        vm.expectRevert(PostRegistry.InvalidPostId.selector);
        registry.getPost(99999);
    }
}

