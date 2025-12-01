// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/PostRegistry.sol";

contract DeployPostRegistry is Script {
    function run() external {
        // Load private key from environment:
        // export PRIVATE_KEY=0xyourkey
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        PostRegistry registry = new PostRegistry();

        vm.stopBroadcast();

        console2.log("PostRegistry deployed at:", address(registry));
    }
}
