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

/// @notice Testnet deployment script (e.g., Avalanche Fuji).
/// @dev Reads AUTHORITY_OWNER from env so you can use a multisig / hot wallet.
contract DeployTestnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address authorityOwner = vm.envAddress("AUTHORITY_OWNER");

        vm.startBroadcast(deployerPrivateKey);

        // Authority + token
        Authority authority = new Authority(authorityOwner);
        VSPToken token = new VSPToken(address(authority));

        // Grant roles to authority owner (multisig or ops wallet).
        authority.setMinter(authorityOwner, true);
        authority.setBurner(authorityOwner, true);

        // Core protocol contracts
        PostRegistry registry = new PostRegistry();
        LinkGraph graph = new LinkGraph(authorityOwner);
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

        // CRITICAL: StakeEngine must be allowed to mint/burn for epoch settlement
        authority.setMinter(address(stake), true);
        authority.setBurner(address(stake), true);

        // Wire registry <-> graph
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        console2.log("Authority:", address(authority));
        console2.log("VSPToken:", address(token));
        console2.log("PostRegistry:", address(registry));
        console2.log("LinkGraph:", address(graph));
        console2.log("StakeEngine:", address(stake));
        console2.log("ScoreEngine:", address(score));
        console2.log("ProtocolViews:", address(views_));

        vm.stopBroadcast();
    }
}

