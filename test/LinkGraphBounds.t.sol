// SPDX-License-Identifier: MIT
// bundle05_c: tests for per-claim incoming/outgoing edge caps (G-7).
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/LinkGraph.sol";

contract LinkGraphBoundsTest is Test {
    LinkGraph graph;

    function setUp() public {
        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))), abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );

        // This test contract acts as the registry so it can call addEdge directly.
        graph.setRegistry(address(this));
    }

    function test_constants() public {
        assertEq(graph.MAX_OUTGOING_LINKS_PER_CLAIM(), 1000);
        assertEq(graph.MAX_INCOMING_LINKS_PER_CLAIM(), 1000);
    }

    function test_outgoingCap_at999_succeeds() public {
        // Push 1000 outgoing edges from claim 1 to claims 2..1001. Each is
        // unique on (from, to, isChallenge) so DuplicateEdge does not fire.
        // The 1000th push (i.e. when current length is 999) must succeed —
        // the cap check is `>=` so 999 < 1000 passes.
        for (uint256 i = 0; i < 1000; i++) {
            graph.addEdge(1, 2 + i, 100000 + i, false);
        }
        LinkGraph.Edge[] memory edges = graph.getOutgoing(1);
        assertEq(edges.length, 1000);
    }

    function test_outgoingCap_at1000_reverts() public {
        // Fill to exactly 1000.
        for (uint256 i = 0; i < 1000; i++) {
            graph.addEdge(1, 2 + i, 100000 + i, false);
        }
        // The 1001st push must revert with OutgoingLinkLimitExceeded.
        vm.expectRevert(abi.encodeWithSelector(LinkGraph.OutgoingLinkLimitExceeded.selector, uint256(1), uint256(1000)));
        graph.addEdge(1, 99999, 999999, false);

        // Confirm storage state was NOT mutated by the failed attempt.
        LinkGraph.Edge[] memory edges = graph.getOutgoing(1);
        assertEq(edges.length, 1000);
    }

    function test_incomingCap_at999_succeeds() public {
        // Push 1000 incoming edges to claim 1 from claims 2..1001.
        for (uint256 i = 0; i < 1000; i++) {
            graph.addEdge(2 + i, 1, 100000 + i, false);
        }
        LinkGraph.IncomingEdge[] memory edges = graph.getIncoming(1);
        assertEq(edges.length, 1000);
    }

    function test_incomingCap_at1000_reverts() public {
        // Fill incoming[1] to exactly 1000.
        for (uint256 i = 0; i < 1000; i++) {
            graph.addEdge(2 + i, 1, 100000 + i, false);
        }
        // The 1001st push (which would make incoming[1] length 1001) must
        // revert. Note: we use a `from` (99999) not yet seen to keep the
        // outgoing side at length 1 — well below the outgoing cap — so it's
        // unambiguously the incoming cap that fires.
        vm.expectRevert(abi.encodeWithSelector(LinkGraph.IncomingLinkLimitExceeded.selector, uint256(1), uint256(1000)));
        graph.addEdge(99999, 1, 999999, false);

        // Confirm storage state was NOT mutated.
        LinkGraph.IncomingEdge[] memory edges = graph.getIncoming(1);
        assertEq(edges.length, 1000);
    }

    function test_outgoingCap_atomicRevert_doesNotMutateIncoming() public {
        // Fill outgoing[1] to 1000 (also writes incoming[2..1001]).
        for (uint256 i = 0; i < 1000; i++) {
            graph.addEdge(1, 2 + i, 100000 + i, false);
        }
        // Attempting a 1001st outgoing from 1 must revert.
        // The target claim (2000) has 0 incoming. After revert, it must still
        // have 0 incoming (atomic check before any .push() per design).
        vm.expectRevert(abi.encodeWithSelector(LinkGraph.OutgoingLinkLimitExceeded.selector, uint256(1), uint256(1000)));
        graph.addEdge(1, 2000, 999999, false);

        LinkGraph.IncomingEdge[] memory edges = graph.getIncoming(2000);
        assertEq(edges.length, 0);
    }

    function test_capDoesNotAffectOtherClaims() public {
        // Fill outgoing[1] to its cap.
        for (uint256 i = 0; i < 1000; i++) {
            graph.addEdge(1, 2 + i, 100000 + i, false);
        }
        // Another claim's outgoing should be unaffected.
        graph.addEdge(2, 3, 200000, true);
        assertEq(graph.getOutgoing(2).length, 1);
    }
}
