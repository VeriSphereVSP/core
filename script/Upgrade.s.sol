// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../src/VerisphereForwarder.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

/// @title Upgrade
/// @notice Deploys new implementation contracts and upgrades existing proxies.
///         Reads proxy addresses from addresses.json. State is preserved.
contract Upgrade is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Read existing addresses
        string memory jsonFile = vm.readFile(
            "broadcast/Deploy.s.sol/43113/addresses.json"
        );
        address forwarderAddr = vm.parseJsonAddress(jsonFile, ".Forwarder");
        address postRegistryProxy = vm.parseJsonAddress(
            jsonFile,
            ".PostRegistry"
        );
        address linkGraphProxy = vm.parseJsonAddress(jsonFile, ".LinkGraph");
        address stakeEngineProxy = vm.parseJsonAddress(
            jsonFile,
            ".StakeEngine"
        );
        address scoreEngineProxy = vm.parseJsonAddress(
            jsonFile,
            ".ScoreEngine"
        );
        address protocolViewsProxy = vm.parseJsonAddress(
            jsonFile,
            ".ProtocolViews"
        );

        console.log("Upgrading with forwarder:", forwarderAddr);
        console.log("PostRegistry proxy:", postRegistryProxy);
        console.log("LinkGraph proxy:", linkGraphProxy);
        console.log("StakeEngine proxy:", stakeEngineProxy);
        console.log("ScoreEngine proxy:", scoreEngineProxy);
        console.log("ProtocolViews proxy:", protocolViewsProxy);

        vm.startBroadcast(pk);

        // Deploy new implementations (forwarder is immutable in constructor)
        PostRegistry newRegistryImpl = new PostRegistry(forwarderAddr);
        console.log("New PostRegistry impl:", address(newRegistryImpl));

        LinkGraph newGraphImpl = new LinkGraph(forwarderAddr);
        console.log("New LinkGraph impl:", address(newGraphImpl));

        StakeEngine newStakeImpl = new StakeEngine(forwarderAddr);
        console.log("New StakeEngine impl:", address(newStakeImpl));

        ScoreEngine newScoreImpl = new ScoreEngine(forwarderAddr);
        console.log("New ScoreEngine impl:", address(newScoreImpl));

        ProtocolViews newViewsImpl = new ProtocolViews(forwarderAddr);
        console.log("New ProtocolViews impl:", address(newViewsImpl));

        // Upgrade each proxy (UUPS: call upgradeToAndCall on the proxy)
        // Empty bytes for no re-initialization call
        UUPSUpgradeable(postRegistryProxy).upgradeToAndCall(
            address(newRegistryImpl),
            bytes("")
        );
        console.log("PostRegistry upgraded");

        UUPSUpgradeable(linkGraphProxy).upgradeToAndCall(
            address(newGraphImpl),
            bytes("")
        );
        console.log("LinkGraph upgraded");

        UUPSUpgradeable(stakeEngineProxy).upgradeToAndCall(
            address(newStakeImpl),
            bytes("")
        );
        console.log("StakeEngine upgraded");

        UUPSUpgradeable(scoreEngineProxy).upgradeToAndCall(
            address(newScoreImpl),
            bytes("")
        );
        console.log("ScoreEngine upgraded");

        UUPSUpgradeable(protocolViewsProxy).upgradeToAndCall(
            address(newViewsImpl),
            bytes("")
        );
        console.log("ProtocolViews upgraded");

        vm.stopBroadcast();

        console.log("");
        console.log("All proxies upgraded. Addresses unchanged.");
    }
}
