// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title LinkGraph
/// @notice Enforces a DAG over claim-to-claim links.
///         Stores ONLY adjacency needed for cycle detection.
contract LinkGraph {
    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error RegistryAlreadySet();
    error NotRegistry();
    error NotOwner();
    error ZeroAddress();
    error SelfLoop();
    error CycleDetected();
    error TraversalLimitExceeded();
    error EdgeAlreadyExists();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event RegistrySet(address indexed registry);
    event EdgeAdded(uint256 indexed fromPostId, uint256 indexed toPostId);

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public immutable owner;
    address public registry;

    // postId => outgoing edges
    mapping(uint256 => uint256[]) private outgoing;

    // Dedup: from => (to => bool)
    mapping(uint256 => mapping(uint256 => bool)) private hasEdge;

    // DFS bookkeeping
    mapping(uint256 => uint256) private visited;
    uint256 private visitToken;

    uint256 public constant MAX_VISITS = 4096;

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    // ---------------------------------------------------------------------
    // Constructor / setup
    // ---------------------------------------------------------------------

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
    }

    /// @notice One-time registry binding (admin-controlled)
    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        if (registry != address(0)) revert RegistryAlreadySet();
        registry = registry_;
        emit RegistrySet(registry_);
    }

    // ---------------------------------------------------------------------
    // External API
    // ---------------------------------------------------------------------

    /// @notice Adds edge `from -> to`, reverting if it creates a cycle.
    function addEdge(uint256 fromPostId, uint256 toPostId) external onlyRegistry {
        if (fromPostId == toPostId) revert SelfLoop();

        // Prevent duplicates (big gas + safety improvement)
        if (hasEdge[fromPostId][toPostId]) revert EdgeAlreadyExists();

        // If path already exists: to -> ... -> from, this creates a cycle
        if (_pathExists(toPostId, fromPostId)) revert CycleDetected();

        hasEdge[fromPostId][toPostId] = true;
        outgoing[fromPostId].push(toPostId);
        emit EdgeAdded(fromPostId, toPostId);
    }

    function getOutgoing(uint256 postId) external view returns (uint256[] memory) {
        return outgoing[postId];
    }

    function edgeExists(uint256 fromPostId, uint256 toPostId) external view returns (bool) {
        return hasEdge[fromPostId][toPostId];
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

            uint256[] storage nbrs = outgoing[node];
            for (uint256 i = 0; i < nbrs.length; i++) {
                uint256 nxt = nbrs[i];
                if (visited[nxt] == token) continue;

                if (visitedCount >= MAX_VISITS) {
                    revert TraversalLimitExceeded();
                }

                visited[nxt] = token;
                stack[sp++] = nxt;
                visitedCount++;
            }
        }

        return false;
    }
}
