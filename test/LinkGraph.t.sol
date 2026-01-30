// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/LinkGraph.sol";

contract LinkGraphUnitTest is Test {
    LinkGraph graph;

    function setUp() public {
        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph()),
                    abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );

        graph.setRegistry(address(this));
    }

    function test_AddEdgeStoresIncomingAndOutgoing() public {
        graph.addEdge(1, 2, 99, true);

        LinkGraph.Edge[] memory out1 = graph.getOutgoing(1);
        assertEq(out1.length, 1);
        assertEq(out1[0].toClaimPostId, 2);
        assertEq(out1[0].linkPostId, 99);
        assertTrue(out1[0].isChallenge);

        LinkGraph.IncomingEdge[] memory in2 = graph.getIncoming(2);
        assertEq(in2.length, 1);
        assertEq(in2[0].fromClaimPostId, 1);
        assertEq(in2[0].linkPostId, 99);
        assertTrue(in2[0].isChallenge);
    }
}

