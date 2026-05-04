// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract DeployTimelock is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address safeAddr = vm.envAddress("SAFE_ADDRESS");
        uint256 minDelay = vm.envUint("TIMELOCK_DELAY_SECONDS");

        // Proposers: only the Safe can schedule operations.
        address[] memory proposers = new address[](1);
        proposers[0] = safeAddr;

        // Executors: only the Safe can execute (after delay).
        address[] memory executors = new address[](1);
        executors[0] = safeAddr;

        // Admin: address(0) means no admin role. The Timelock manages
        // its own configuration through the same propose/execute
        // mechanism. This is the recommended production config.
        address admin = address(0);

        vm.startBroadcast(deployerKey);
        TimelockController timelock = new TimelockController(
            minDelay,
            proposers,
            executors,
            admin
        );
        vm.stopBroadcast();

        console.log("Timelock deployed at:", address(timelock));
        console.log("Min delay (seconds):", minDelay);
        console.log("Proposer:", safeAddr);
        console.log("Executor:", safeAddr);
    }
}
