// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockPostingFeePolicy.sol";

contract LinkGraphAcyclicTest is Test {
    PostRegistry registry;
    LinkGraph graph;

    function setUp() public {
        MockVSP vsp = new MockVSP();
        MockPostingFeePolicy feePolicy = new MockPostingFeePolicy(100);

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

    function test_OutgoingEdges_ReturnTypedStruct() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, false);

        LinkGraph.Edge[] memory edges = graph.getOutgoing(a);
        assertEq(edges.length, 1);
        assertEq(edges[0].toClaimPostId, b);
        assertEq(edges[0].linkPostId, linkPostId);
        assertEq(edges[0].isChallenge, false);
    }

    function test_CyclesAreAllowed() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        registry.createLink(a, b, false);
        registry.createLink(b, c, false);

        // Cycle A->B->C->A is allowed
        uint256 linkPostId = registry.createLink(c, a, false);
        assertTrue(linkPostId > 0, "cycle link should succeed");

        LinkGraph.Edge[] memory outC = graph.getOutgoing(c);
        assertEq(outC.length, 1);
        assertEq(outC[0].toClaimPostId, a);
    }

    function test_Acyclic_AllowsDAG() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        registry.createLink(a, b, false);
        registry.createLink(a, c, false);
        registry.createLink(b, c, false);

        LinkGraph.Edge[] memory outA = graph.getOutgoing(a);
        assertEq(outA.length, 2);

        LinkGraph.IncomingEdge[] memory inC = graph.getIncoming(c);
        assertEq(inC.length, 2);
    }
}
