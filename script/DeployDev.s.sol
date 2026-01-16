// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "../src/authority/Authority.sol";
import "../src/VSPToken.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

contract DeployDev is Script {
    using stdJson for string;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address deployer = msg.sender;

        Authority authority = new Authority(deployer);
        VSPToken token = new VSPToken(address(authority));

        authority.setMinter(deployer, true);
        authority.setBurner(deployer, true);

        PostRegistry registry = new PostRegistry();
        LinkGraph graph = new LinkGraph(deployer);
        StakeEngine stake = new StakeEngine(address(token));
        ScoreEngine score = new ScoreEngine(
            address(registry),
            address(stake),
            address(graph)
        );
        ProtocolViews views_ = new ProtocolViews(
            address(registry),
            address(stake),
            address(graph),
            address(score)
        );

        authority.setMinter(address(stake), true);
        authority.setBurner(address(stake), true);

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vm.stopBroadcast();

        _writeJson(
            "deployments/dev.json",
            "local-dev",
            authority,
            token,
            registry,
            graph,
            stake,
            score,
            views_
        );
    }

    function _writeJson(
        string memory path,
        string memory chain,
        Authority authority,
        VSPToken token,
        PostRegistry registry,
        LinkGraph graph,
        StakeEngine stake,
        ScoreEngine score,
        ProtocolViews views_
    ) internal {
        string memory json;
        json = json.serialize("chain", chain);
        json = json.serialize("Authority", address(authority));
        json = json.serialize("VSPToken", address(token));
        json = json.serialize("PostRegistry", address(registry));
        json = json.serialize("LinkGraph", address(graph));
        json = json.serialize("StakeEngine", address(stake));
        json = json.serialize("ScoreEngine", address(score));
        json = json.serialize("ProtocolViews", address(views_));

        vm.writeJson(json, path);
    }
}

