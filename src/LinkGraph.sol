// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./governance/GovernedUpgradeable.sol";

/// @title LinkGraph
/// @notice Directed graph of evidence links between claims.
///         Allows cycles — the ScoreEngine's depth limit (32) prevents
///         infinite recursion and the attenuation factor ensures convergence.
///         Mutually contradictory claims (A challenges B, B challenges A) are
///         a natural pattern that the graph must support.
contract LinkGraph is GovernedUpgradeable {
    error RegistryAlreadySet();
    error NotRegistry();
    error SelfLoop();
    error DuplicateEdge(
        uint256 fromClaimPostId,
        uint256 toClaimPostId,
        bool isChallenge
    );

    event RegistrySet(address indexed registry);
    event EdgeAdded(
        uint256 indexed from,
        uint256 indexed to,
        uint256 indexed linkPostId,
        bool isChallenge
    );

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

    // ── Legacy storage slots (preserved for upgrade compatibility) ──
    mapping(uint256 => uint256) private _unused_visited;
    uint256 private _unused_visitToken;
    uint256 public constant MAX_VISITS = 4096; // kept for ABI compat

    // Duplicate edge detection: keccak256(from, to, isChallenge) => true
    mapping(bytes32 => bool) private edgeExists;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address trustedForwarder_
    ) GovernedUpgradeable(trustedForwarder_) {}

    function initialize(address governance_) external initializer {
        __GovernedUpgradeable_init(governance_);
    }

    modifier onlyRegistry() {
        if (msg.sender != registry) revert NotRegistry();
        _;
    }

    function setRegistry(address registry_) external onlyGovernance {
        if (registry != address(0)) revert RegistryAlreadySet();
        if (registry_ == address(0)) revert ZeroAddress();
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

        bytes32 edgeKey = keccak256(
            abi.encodePacked(fromClaimPostId, toClaimPostId, isChallenge)
        );
        if (edgeExists[edgeKey])
            revert DuplicateEdge(fromClaimPostId, toClaimPostId, isChallenge);

        edgeExists[edgeKey] = true;

        outgoing[fromClaimPostId].push(
            Edge({
                toClaimPostId: toClaimPostId,
                linkPostId: linkPostId,
                isChallenge: isChallenge
            })
        );

        incoming[toClaimPostId].push(
            IncomingEdge({
                fromClaimPostId: fromClaimPostId,
                linkPostId: linkPostId,
                isChallenge: isChallenge
            })
        );

        emit EdgeAdded(fromClaimPostId, toClaimPostId, linkPostId, isChallenge);
    }

    function getOutgoing(
        uint256 claimPostId
    ) external view returns (Edge[] memory) {
        return outgoing[claimPostId];
    }

    function getIncoming(
        uint256 claimPostId
    ) external view returns (IncomingEdge[] memory) {
        return incoming[claimPostId];
    }

    /// @notice Check if a specific edge already exists.
    function hasEdge(
        uint256 fromClaimPostId,
        uint256 toClaimPostId,
        bool isChallenge
    ) external view returns (bool) {
        bytes32 edgeKey = keccak256(
            abi.encodePacked(fromClaimPostId, toClaimPostId, isChallenge)
        );
        return edgeExists[edgeKey];
    }

    function getOutgoingClaims(
        uint256 claimPostId
    ) external view returns (uint256[] memory) {
        Edge[] storage edges = outgoing[claimPostId];
        uint256[] memory tos = new uint256[](edges.length);
        for (uint256 i = 0; i < edges.length; i++) {
            tos[i] = edges[i].toClaimPostId;
        }
        return tos;
    }

    uint256[500] private __gap;
}
