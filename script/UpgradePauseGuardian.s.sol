// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../src/PostRegistry.sol";
import "../src/StakeEngine.sol";

contract UpgradePauseGuardian is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        // Read existing addresses
        string memory jsonFile = vm.readFile(
            "broadcast/Deploy.s.sol/43113/addresses.json"
        );
        address forwarderAddr = vm.envOr(
            "FORWARDER_ADDRESS",
            _tryParseForwarder(jsonFile)
        );
        address postRegistryProxy = vm.parseJsonAddress(
            jsonFile,
            ".PostRegistry"
        );
        address stakeEngineProxy = vm.parseJsonAddress(
            jsonFile,
            ".StakeEngine"
        );

        // Guardian for practice = deployer EOA.
        address guardian = vm.envOr("GUARDIAN_ADDRESS", deployer);

        console.log("=== patch12b Upgrade ===");
        console.log("Forwarder:", forwarderAddr);
        console.log("PostRegistry proxy:", postRegistryProxy);
        console.log("StakeEngine proxy:", stakeEngineProxy);
        console.log("Guardian:", guardian);
        console.log("");

        vm.startBroadcast(pk);

        // ── PostRegistry ────────────────────────────────────────────
        PostRegistry newPRImpl = new PostRegistry(forwarderAddr);
        console.log("New PostRegistry impl:", address(newPRImpl));

        UUPSUpgradeable(postRegistryProxy).upgradeToAndCall(
            address(newPRImpl),
            abi.encodeCall(PostRegistry.initializeV2, (guardian))
        );
        console.log("PostRegistry: upgraded + initializeV2(guardian)");

        // ── StakeEngine ─────────────────────────────────────────────
        StakeEngine newSEImpl = new StakeEngine(forwarderAddr);
        console.log("New StakeEngine impl:", address(newSEImpl));

        UUPSUpgradeable(stakeEngineProxy).upgradeToAndCall(
            address(newSEImpl),
            abi.encodeCall(StakeEngine.initializeV2, (guardian))
        );
        console.log("StakeEngine: upgraded + initializeV2(guardian)");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade complete ===");
    }

    function _tryParseForwarder(
        string memory json
    ) internal view returns (address) {
        try vm.parseJsonAddress(json, ".Forwarder") returns (address f) {
            return f;
        } catch {
            return address(0);
        }
    }
}
