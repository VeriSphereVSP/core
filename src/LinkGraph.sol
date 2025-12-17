// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LinkGraph
/// @notice Enforces a DAG over claim-to-claim edges and indexes incoming edges by dependent claim.
///         Stores adjacency for:
///         (a) cycle detection (outgoing nodes)
///         (b) link enrichment (incoming edges with linkPostId)
contract LinkGraph {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotRegistry();
    error SelfLoop();
    error CycleDetected();
    error TraversalLimitExceeded();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event EdgeAdded(uint256 indexed fromPostId, uint256 indexed toPostId, uint256 indexed linkPostId);

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct IncomingEdge {
        uint256 fromPostId;  // independent claim postId
        uint256 linkPostId;  // the PostRegistry postId for the Link post
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public immutable registry;

    // For cycle detection: postId => outgoing neighbor claimIds
    mapping(uint256 => uint256[]) private outgoing;

    // For enrichment: dependent claimId => list of (from, linkPostId)
    mapping(uint256 => IncomingEdge[]) private incoming;

    // DFS bookkeeping
    mapping(uint256 => uint256) private visited;
    uint256 private visitToken;

    uint256 public constant MAX_VISITS = 4096;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address registry_) {
        registry = registry_;
    }

    // ---------------------------------------------------------------------
    // External API
    // ---------------------------------------------------------------------

    /// @notice Adds edge `from -> to` with associated `linkPostId`, reverting if it creates a cycle.
    function addEdge(uint256 fromPostId, uint256 toPostId, uint256 linkPostId)
        external
        onlyRegistry
    {
        if (fromPostId == toPostId) revert SelfLoop();

        // If path already exists: to -> ... -> from, this creates a cycle
        if (_pathExists(toPostId, fromPostId)) revert CycleDetected();

        outgoing[fromPostId].push(toPostId);
        incoming[toPostId].push(IncomingEdge({ fromPostId: fromPostId, linkPostId: linkPostId }));

        emit EdgeAdded(fromPostId, toPostId, linkPostId);
    }

    function getOutgoing(uint256 postId) external view returns (uint256[] memory) {
        return outgoing[postId];
    }

    function getIncoming(uint256 postId) external view returns (IncomingEdge[] memory) {
        return incoming[postId];
    }

    // ---------------------------------------------------------------------
    // Internal DFS (bounded)
    // ---------------------------------------------------------------------

    function _pathExists(uint256 start, uint256 target) internal returns (bool) {
        visitToken++;
        uint256 token = visitToken;

        uint256[] memory stack = new uint256[](MAX_VISITS);
        uint256 sp = 0;
        uint256 visitedCount = 0;

        visited[start] = token;
        stack[sp++] = start;
        visitedCount++;

        while (sp > 0) {
            uint256 node = stack[--sp];
            if (node == target) return true;

            uint256[] storage nbrs = outgoing[node];
            for (uint256 i = 0; i < nbrs.length; i++) {
                uint256 nxt = nbrs[i];
                if (visited[nxt] == token) continue;

                if (visitedCount >= MAX_VISITS) revert TraversalLimitExceeded();

                visited[nxt] = token;
                stack[sp++] = nxt;
                visitedCount++;
            }
        }

        return false;
    }
}
