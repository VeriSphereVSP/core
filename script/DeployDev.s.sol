// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/authority/Authority.sol";
import "../src/VSPToken.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

contract DeployDev is Script {
    function run() external {
        vm.startBroadcast();

        Authority authority = new Authority(msg.sender);

        VSPToken token = new VSPToken(address(authority));
        authority.setMinter(msg.sender, true);
        authority.setBurner(msg.sender, true);

        PostRegistry registry = new PostRegistry();
        LinkGraph graph = new LinkGraph();
        StakeEngine stake = new StakeEngine(token);
        ScoreEngine score = new ScoreEngine(registry, stake, graph);
        ProtocolViews views = new ProtocolViews(
            address(registry),
            address(stake),
            address(graph),
            address(score)
        );

        graph.setRegistry(registry);
        registry.setLinkGraph(graph);

        vm.stopBroadcast();
    }
}

