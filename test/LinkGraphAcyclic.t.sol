// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";

contract LinkGraphAcyclicTest is Test {
    PostRegistry registry;
    LinkGraph graph;

    uint256 constant MAX_CLAIMS = 20;

    function setUp() public {
        // Deploy registry FIRST
        registry = new PostRegistry();

        // Deploy graph with registry as the only caller
        graph = new LinkGraph(address(registry));

        // Bind registry -> graph
        registry.setLinkGraph(address(graph));
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    function _createClaims(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            registry.createClaim(
                string(abi.encodePacked("claim-", vm.toString(i)))
            );
        }
    }

    /// Off-chain DFS used ONLY inside the test to assert no cycles exist
    function _assertAcyclic() internal view {
        uint256 n = registry.nextPostId();

        bool[] memory visited = new bool[](n);
        bool[] memory stack = new bool[](n);

        for (uint256 i = 0; i < n; i++) {
            (, , PostRegistry.ContentType t, ) = registry.getPost(i);
            if (t == PostRegistry.ContentType.Claim && !visited[i]) {
                _dfsCheck(i, visited, stack);
            }
        }
    }

    function _dfsCheck(
        uint256 node,
        bool[] memory visited,
        bool[] memory stack
    ) internal view {
        visited[node] = true;
        stack[node] = true;

        uint256[] memory edges = graph.getOutgoing(node);
        for (uint256 i = 0; i < edges.length; i++) {
            uint256 nxt = edges[i];
            if (!visited[nxt]) {
                _dfsCheck(nxt, visited, stack);
            } else {
                // back-edge → cycle
                assertFalse(stack[nxt], "cycle detected");
            }
        }

        stack[node] = false;
    }

    // ------------------------------------------------------------
    // FUZZ / PROPERTY TEST
    // ------------------------------------------------------------

    /// @notice Property: no sequence of successful link creations can form a cycle
    function testFuzz_NoCycles(uint256 seed) public {
        uint256 claimCount = bound(seed, 2, MAX_CLAIMS);
        _createClaims(claimCount);

        // Randomized link attempts
        for (uint256 i = 0; i < 200; i++) {
            uint256 from = uint256(
                keccak256(abi.encode(seed, i, "from"))
            ) % claimCount;

            uint256 to = uint256(
                keccak256(abi.encode(seed, i, "to"))
            ) % claimCount;

            if (from == to) continue;

            // Attempt link — may revert if it would form a cycle
            try registry.createLink(from, to, false) {
                // If it succeeded, assert global invariant
                _assertAcyclic();
            } catch {
                // Revert is expected when a cycle would be formed
            }
        }

        // Final global assertion
        _assertAcyclic();
    }
}
