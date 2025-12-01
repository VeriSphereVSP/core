// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PostRegistry.sol";

contract SetStakeEngine is Script {
    function run() external {
        address postRegistryAddr = vm.envAddress("POST_REGISTRY_ADDRESS");
        address stakeEngineAddr = vm.envAddress("STAKE_ENGINE_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        PostRegistry(postRegistryAddr).setStakeEngine(stakeEngineAddr);

        vm.stopBroadcast();

        console.log("StakeEngine set to:", stakeEngineAddr);
    }
}

