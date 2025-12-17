// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LinkGraph
/// @notice Enforces a DAG over claim-to-claim links.
///         Stores adjacency + minimal edge metadata for read APIs.
contract LinkGraph {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error RegistryAlreadySet();
    error NotRegistry();
    error NotOwner();
    error SelfLoop();
    error CycleDetected();
    error TraversalLimitExceeded();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event RegistrySet(address indexed registry);
    event EdgeAdded(
        uint256 indexed fromClaimPostId,
        uint256 indexed toClaimPostId,
        uint256 indexed linkPostId,
        bool isChallenge
    );

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    struct Edge {
        uint256 toClaimPostId;
        uint256 linkPostId;
        bool isChallenge;
    }

    struct IncomingEdge {
        uint256 fromClaimPostId;
        uint256 linkPostId;
        bool isChallenge;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public owner;
    address public registry;

    // claimPostId => outgoing edges
    mapping(uint256 => Edge[]) private outgoing;

    // claimPostId => incoming edges
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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor / setup
    // ---------------------------------------------------------------------

    constructor(address owner_) {
        owner = owner_;
    }

    function setRegistry(address registry_) external onlyOwner {
        if (registry != address(0)) revert RegistryAlreadySet();
        registry = registry_;
        emit RegistrySet(registry_);
    }

    // ---------------------------------------------------------------------
    // External API
    // ---------------------------------------------------------------------

    /// @notice Adds edge `from -> to`, reverting if it creates a cycle.
    /// @dev Only the registry may call.
    function addEdge(
        uint256 fromClaimPostId,
        uint256 toClaimPostId,
        uint256 linkPostId,
        bool isChallenge
    ) external onlyRegistry {
        if (fromClaimPostId == toClaimPostId) revert SelfLoop();

        // If path already exists: to -> ... -> from, this creates a cycle
        if (_pathExists(toClaimPostId, fromClaimPostId)) revert CycleDetected();

        outgoing[fromClaimPostId].push(
            Edge({toClaimPostId: toClaimPostId, linkPostId: linkPostId, isChallenge: isChallenge})
        );

        incoming[toClaimPostId].push(
            IncomingEdge({fromClaimPostId: fromClaimPostId, linkPostId: linkPostId, isChallenge: isChallenge})
        );

        emit EdgeAdded(fromClaimPostId, toClaimPostId, linkPostId, isChallenge);
    }

    function getOutgoing(uint256 claimPostId) external view returns (Edge[] memory) {
        return outgoing[claimPostId];
    }

    function getIncoming(uint256 claimPostId) external view returns (IncomingEdge[] memory) {
        return incoming[claimPostId];
    }

    /// Convenience for tests / indexers that only want adjacency.
    function getOutgoingClaims(uint256 claimPostId) external view returns (uint256[] memory) {
        Edge[] storage edges = outgoing[claimPostId];
        uint256[] memory tos = new uint256[](edges.length);
        for (uint256 i = 0; i < edges.length; i++) {
            tos[i] = edges[i].toClaimPostId;
        }
        return tos;
    }

    // ---------------------------------------------------------------------
    // Internal DFS
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

            Edge[] storage nbrs = outgoing[node];
            for (uint256 i = 0; i < nbrs.length; i++) {
                uint256 nxt = nbrs[i].toClaimPostId;
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
