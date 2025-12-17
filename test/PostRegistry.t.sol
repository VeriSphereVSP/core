// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

contract PostRegistryTest is Test {
    PostRegistry registry;
    LinkGraph graph;

    function setUp() public {
        // Deploy registry
        registry = new PostRegistry();

        // Deploy graph with registry as the authorized caller
        graph = new LinkGraph(address(registry));

        // Bind registry -> graph
        registry.setLinkGraph(address(graph));
    }

    function testCreateClaim() public {
        uint256 id = registry.createClaim("Hello world");

        (
            address creator,
            uint256 timestamp,
            PostRegistry.ContentType contentType,
            uint256 contentId
        ) = registry.getPost(id);

        assertEq(creator, address(this));
        assertTrue(timestamp > 0);
        assertEq(uint8(contentType), uint8(PostRegistry.ContentType.Claim));

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
            uint256 linkId
        ) = registry.getPost(linkPostId);

        assertEq(uint8(contentType), uint8(PostRegistry.ContentType.Link));

        (uint256 from, uint256 to, bool isChallenge) = registry.getLink(linkId);
        assertEq(from, a);
        assertEq(to, b);
        assertFalse(isChallenge);
    }

    function testCreateChallengeLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, true);

        (, , , uint256 linkId) = registry.getPost(linkPostId);
        (, , bool isChallenge) = registry.getLink(linkId);

        assertTrue(isChallenge);
    }

    function test_RevertWhen_IndependentClaimDoesNotExist() public {
        uint256 b = registry.createClaim("B");

        vm.expectRevert(PostRegistry.IndependentPostDoesNotExist.selector);
        registry.createLink(9999, b, false);
    }

    function test_RevertWhen_DependentClaimDoesNotExist() public {
        uint256 a = registry.createClaim("A");

        vm.expectRevert(PostRegistry.DependentPostDoesNotExist.selector);
        registry.createLink(a, 9999, false);
    }

    function test_RevertWhen_EmptyClaimText() public {
        vm.expectRevert(PostRegistry.InvalidClaim.selector);
        registry.createClaim("");
    }
}
