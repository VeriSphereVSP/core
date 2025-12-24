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

contract DeployTestnet is Script {
    string constant VERSION = "v0.4-testnet";

    function run() external {
        require(
            keccak256(bytes(vm.envString("DEPLOY_VERSION"))) ==
                keccak256(bytes(VERSION)),
            "DEPLOY_VERSION mismatch"
        );

        vm.startBroadcast();

        Authority authority = new Authority(msg.sender);

        VSPToken token = new VSPToken(address(authority));

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

        authority.setMinter(address(stake), true);
        authority.setBurner(address(stake), true);

        vm.stopBroadcast();
    }
}

