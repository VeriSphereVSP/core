// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

contract PostRegistryTest is Test {
    PostRegistry registry;
    LinkGraph graph;

    function setUp() public {
        registry = new PostRegistry();
        graph = new LinkGraph();

        registry.setLinkGraph(address(graph));
        graph.setRegistry(address(registry));
    }

    function testCreateClaim() public {
        uint256 id = registry.createClaim("Hello");

        (address creator,, PostRegistry.ContentType t, uint256 cid) =
            registry.getPost(id);

        assertEq(creator, address(this));
        assertEq(uint8(t), uint8(PostRegistry.ContentType.Claim));
        assertEq(registry.getClaim(cid), "Hello");
    }

    function testCreateSupportLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, false);

        (,, PostRegistry.ContentType t, uint256 linkId) =
            registry.getPost(linkPostId);

        assertEq(uint8(t), uint8(PostRegistry.ContentType.Link));

        (uint256 from, uint256 to, bool isChallenge) =
            registry.getLink(linkId);

        assertEq(from, a);
        assertEq(to, b);
        assertFalse(isChallenge);

        uint256[] memory out = graph.getOutgoing(a);
        assertEq(out.length, 1);
        assertEq(out[0], b);
    }

    function testCreateChallengeLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, true);

        (,, PostRegistry.ContentType t, uint256 linkId) =
            registry.getPost(linkPostId);

        assertEq(uint8(t), uint8(PostRegistry.ContentType.Link));

        (, , bool isChallenge) = registry.getLink(linkId);
        assertTrue(isChallenge);
    }

    function test_RevertWhen_CycleDetected() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        registry.createLink(a, b, false);
        registry.createLink(b, c, false);

        vm.expectRevert(LinkGraph.CycleDetected.selector);
        registry.createLink(c, a, false);
    }

    function test_GetPostReturnsZeroForInvalidId() public {
        (address creator, uint256 ts, PostRegistry.ContentType t, uint256 cid) =
            registry.getPost(999);

        assertEq(creator, address(0));
        assertEq(ts, 0);
        assertEq(uint8(t), 0);
        assertEq(cid, 0);
    }
}
