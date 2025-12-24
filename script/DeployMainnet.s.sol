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

/// @notice Mainnet deployment script.
/// @dev Reads GOVERNANCE_MULTISIG from env and sets it as the authority owner.
contract DeployMainnet is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address governanceMultisig = vm.envAddress("GOVERNANCE_MULTISIG");

        vm.startBroadcast(deployerPrivateKey);

        // Authority is permanently owned by the governance multisig
        Authority authority = new Authority(governanceMultisig);
        VSPToken token = new VSPToken(address(authority));

        // Grant mint/burn roles to governance multisig
        authority.setMinter(governanceMultisig, true);
        authority.setBurner(governanceMultisig, true);

        // Core protocol contracts
        PostRegistry registry = new PostRegistry();
        LinkGraph graph = new LinkGraph(governanceMultisig);
        StakeEngine stake = new StakeEngine(address(token));
        ScoreEngine score = new ScoreEngine(
            address(registry),
            address(graph),
            address(stake)
        );
        ProtocolViews views_ = new ProtocolViews(
            address(registry),
            address(stake),
            address(graph),
            address(score)
        );

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

