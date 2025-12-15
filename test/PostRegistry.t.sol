// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import "../src/PostRegistry.sol";

contract PostRegistryTest is Test {
    PostRegistry registry;

    function setUp() public {
        registry = new PostRegistry();
    }

    function testCreateClaim() public {
        uint256 postId = registry.createClaim("Hello world");

        (
            address creator,
            uint256 timestamp,
            PostRegistry.ContentType contentType,
            uint256 contentId
        ) = registry.getPost(postId);

        assertEq(creator, address(this));
        assertTrue(timestamp > 0);
        assertEq(uint8(contentType), uint8(PostRegistry.ContentType.Claim));
        assertEq(contentId, 0);

        string memory text = registry.getClaim(contentId);
        assertEq(text, "Hello world");
    }

    function testCreateSupportLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, false);

        (
            ,
            ,
            PostRegistry.ContentType contentType,
            uint256 contentId
        ) = registry.getPost(linkPostId);

        assertEq(uint8(contentType), uint8(PostRegistry.ContentType.Link));
        assertEq(contentId, 0); // first link

        (
            uint256 independentClaimId,
            uint256 dependentClaimId,
            bool isChallenge
        ) = registry.getLink(contentId);

        assertEq(independentClaimId, a);
        assertEq(dependentClaimId, b);
        assertFalse(isChallenge);
    }

    function testCreateChallengeLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, true);

        (
            ,
            ,
            PostRegistry.ContentType contentType,
            uint256 contentId
        ) = registry.getPost(linkPostId);

        assertEq(uint8(contentType), uint8(PostRegistry.ContentType.Link));
        assertEq(contentId, 0); // first link

        (
            uint256 independentClaimId,
            uint256 dependentClaimId,
            bool isChallenge
        ) = registry.getLink(contentId);

        assertEq(independentClaimId, a);
        assertEq(dependentClaimId, b);
        assertTrue(isChallenge);
    }

    function test_RevertWhen_EmptyClaimText() public {
        vm.expectRevert(PostRegistry.InvalidClaim.selector);
        registry.createClaim("");
    }

    function test_RevertWhen_IndependentClaimDoesNotExist() public {
        registry.createClaim("B");

        vm.expectRevert(PostRegistry.IndependentPostDoesNotExist.selector);
        registry.createLink(9999, 0, false);
    }

    function test_RevertWhen_DependentClaimDoesNotExist() public {
        uint256 a = registry.createClaim("A");

        vm.expectRevert(PostRegistry.DependentPostDoesNotExist.selector);
        registry.createLink(a, 9999, false);
    }

    function test_GetPostReturnsZeroForInvalidId() public view {
        (
            address creator,
            uint256 timestamp,
            PostRegistry.ContentType contentType,
            uint256 contentId
        ) = registry.getPost(9999);

        assertEq(creator, address(0));
        assertEq(timestamp, 0);
        assertEq(uint8(contentType), 0);
        assertEq(contentId, 0);
    }
}

