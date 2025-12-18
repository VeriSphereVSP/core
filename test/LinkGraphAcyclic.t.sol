// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

/// @notice Focused tests for LinkGraph acyclicity and edge typing.
contract LinkGraphAcyclicTest is Test {
    PostRegistry registry;
    LinkGraph graph;

    function setUp() public {
        graph = new LinkGraph(address(this));

        registry = new PostRegistry();
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));
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

    function test_Acyclic_RevertsOnCycle() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        // A -> B, B -> C
        registry.createLink(a, b, false);
        registry.createLink(b, c, false);

        // Attempt C -> A should create a cycle and revert
        vm.expectRevert();
        registry.createLink(c, a, false);
    }

    function test_Acyclic_AllowsDAG() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        // A -> B, A -> C, B -> C (still a DAG)
        registry.createLink(a, b, false);
        registry.createLink(a, c, false);
        registry.createLink(b, c, false);

        // Sanity: outgoing A has 2 edges
        LinkGraph.Edge[] memory outA = graph.getOutgoing(a);
        assertEq(outA.length, 2);

        // Sanity: incoming C has 2 edges
        LinkGraph.IncomingEdge[] memory inC = graph.getIncoming(c);
        assertEq(inC.length, 2);
    }
}
