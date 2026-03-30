// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockPostingFeePolicy.sol";

contract PostRegistryTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    MockVSP vsp;
    MockPostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(100);

        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(
                        PostRegistry.initialize,
                        (address(this), address(vsp), address(feePolicy))
                    )
                )
            )
        );

        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))),
                    abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // Fund test account for posting fees
        vsp.mint(address(this), 1e30);
        vsp.approve(address(registry), type(uint256).max);
    }

    function testCreateClaim() public {
        uint256 id = registry.createClaim("Hello world");

        PostRegistry.Post memory p = registry.getPost(id);
        assertEq(p.creator, address(this));
        assertTrue(p.timestamp > 0);
        assertEq(uint8(p.contentType), uint8(PostRegistry.ContentType.Claim));

        string memory text = registry.getClaim(p.contentId);
        assertEq(text, "Hello world");
    }

    function testCreateSupportLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, false);

        PostRegistry.Post memory lp = registry.getPost(linkPostId);
        assertEq(uint8(lp.contentType), uint8(PostRegistry.ContentType.Link));

        PostRegistry.Link memory l = registry.getLink(lp.contentId);
        assertEq(l.fromPostId, a);
        assertEq(l.toPostId, b);
        assertFalse(l.isChallenge);
    }

    function testCreateChallengeLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, true);

        PostRegistry.Post memory lp = registry.getPost(linkPostId);
        PostRegistry.Link memory l = registry.getLink(lp.contentId);
        assertTrue(l.isChallenge);
    }

    function test_RevertWhen_IndependentClaimDoesNotExist() public {
        uint256 b = registry.createClaim("B");

        vm.expectRevert(PostRegistry.FromPostDoesNotExist.selector);
        registry.createLink(9999, b, false);
    }

    function test_RevertWhen_DependentClaimDoesNotExist() public {
        uint256 a = registry.createClaim("A");

        vm.expectRevert(PostRegistry.ToPostDoesNotExist.selector);
        registry.createLink(a, 9999, false);
    }

    function test_RevertWhen_EmptyClaimText() public {
        vm.expectRevert(PostRegistry.InvalidClaim.selector);
        registry.createClaim("");
    }
}
