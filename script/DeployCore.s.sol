// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import {Authority} from "../src/authority/Authority.sol";
import {VSPToken} from "../src/VSPToken.sol";
import {PostRegistry} from "../src/PostRegistry.sol";
import {LinkGraph} from "../src/LinkGraph.sol";
import {StakeEngine} from "../src/StakeEngine.sol";
import {ScoreEngine} from "../src/ScoreEngine.sol";
import {ProtocolViews} from "../src/ProtocolViews.sol";

/// @title DeployCore
/// @notice End-to-end deployment of the full VeriSphere core:
///         Authority, VSPToken, PostRegistry, LinkGraph, StakeEngine,
///         ScoreEngine, and ProtocolViews.
contract DeployCore is Script {
    function run() external {
        // Use PRIVATE_KEY from env (same pattern as existing scripts)
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // ---------------------------------------------------------------------
        // 1. Authority + VSP token
        // ---------------------------------------------------------------------
        Authority authority = new Authority(deployer);

        VSPToken vsp = new VSPToken(address(authority));

        // Give deployer direct minter/burner rights for bootstrapping
        authority.setMinter(deployer, true);
        authority.setBurner(deployer, true);

        // StakeEngine will mint/burn for epoch gains/losses
        // (these calls are no-op if you later decide to route mint/burn
        //  exclusively via another contract)
        // NOTE: You can comment these out if your final economics differ.
        //       They reflect the current StakeEngine implementation.
        StakeEngine stakeEngine = new StakeEngine(address(vsp));
        authority.setMinter(address(stakeEngine), true);
        authority.setBurner(address(stakeEngine), true);

        // ---------------------------------------------------------------------
        // 2. Registry + LinkGraph wiring
        // ---------------------------------------------------------------------
        PostRegistry registry = new PostRegistry();
        LinkGraph graph = new LinkGraph();

        // Mutual references to enforce graph / registry invariants
        graph.setRegistry(registry);
        registry.setLinkGraph(graph);

        // ---------------------------------------------------------------------
        // 3. ScoreEngine (VS & contextual influence)
        // ---------------------------------------------------------------------
        ScoreEngine scoreEngine = new ScoreEngine(
            address(registry),
            address(stakeEngine),
            address(graph)
        );

        // ---------------------------------------------------------------------
        // 4. ProtocolViews (read-only aggregation)
        // ---------------------------------------------------------------------
        ProtocolViews views = new ProtocolViews(
            address(registry),
            address(stakeEngine),
            address(graph),
            address(scoreEngine)
        );

        vm.stopBroadcast();

        // Log addresses for convenience
        console2.log("Authority:      ", address(authority));
        console2.log("VSPToken:       ", address(vsp));
        console2.log("PostRegistry:   ", address(registry));
        console2.log("LinkGraph:      ", address(graph));
        console2.log("StakeEngine:    ", address(stakeEngine));
        console2.log("ScoreEngine:    ", address(scoreEngine));
        console2.log("ProtocolViews:  ", address(views));
    }
}
