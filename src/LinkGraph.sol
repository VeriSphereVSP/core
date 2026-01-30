// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./governance/GovernedUpgradeable.sol";

contract LinkGraph is GovernedUpgradeable {
    error RegistryAlreadySet();
    error NotRegistry();
    error SelfLoop();
    error CycleDetected();
    error TraversalLimitExceeded();

    event RegistrySet(address indexed registry);
    event EdgeAdded(uint256 indexed from, uint256 indexed to, uint256 indexed linkPostId, bool isChallenge);

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

    address public registry;

    mapping(uint256 => Edge[]) private outgoing;
    mapping(uint256 => IncomingEdge[]) private incoming;

    mapping(uint256 => uint256) private visited;
    uint256 private visitToken;

    uint256 public constant MAX_VISITS = 4096;

    constructor() {
        _disableInitializers();
    }

    function initialize(address governance_) external initializer {
        __GovernedUpgradeable_init(governance_);
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    function setRegistry(address registry_) external onlyGovernance {
        if (registry != address(0)) revert RegistryAlreadySet();
        registry = registry_;
        emit RegistrySet(registry_);
    }

    function addEdge(
        uint256 fromClaimPostId,
        uint256 toClaimPostId,
        uint256 linkPostId,
        bool isChallenge
    ) external onlyRegistry {
        if (fromClaimPostId == toClaimPostId) revert SelfLoop();
        if (_pathExists(toClaimPostId, fromClaimPostId)) revert CycleDetected();

        outgoing[fromClaimPostId].push(
            Edge({ toClaimPostId: toClaimPostId, linkPostId: linkPostId, isChallenge: isChallenge })
        );

        incoming[toClaimPostId].push(
            IncomingEdge({ fromClaimPostId: fromClaimPostId, linkPostId: linkPostId, isChallenge: isChallenge })
        );

        emit EdgeAdded(fromClaimPostId, toClaimPostId, linkPostId, isChallenge);
    }

    function getOutgoing(uint256 claimPostId) external view returns (Edge[] memory) {
        return outgoing[claimPostId];
    }

    function getIncoming(uint256 claimPostId) external view returns (IncomingEdge[] memory) {
        return incoming[claimPostId];
    }

    function _pathExists(uint256 start, uint256 target) internal returns (bool) {
        visitToken++;
        uint256 token = visitToken;

        uint256[] memory stack = new uint256[](MAX_VISITS);
        uint256 sp;
        uint256 visitedCount;

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

    function getOutgoingClaims(uint256 claimPostId)
        external
        view
        returns (uint256[] memory)
    {
        Edge[] storage edges = outgoing[claimPostId];
        uint256[] memory tos = new uint256[](edges.length);
        for (uint256 i = 0; i < edges.length; i++) {
            tos[i] = edges[i].toClaimPostId;
        }
        return tos;
    }


    uint256[50] private __gap;
}

