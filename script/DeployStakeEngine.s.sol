// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StakeEngine.sol";

/// @notice Simple deployment script for StakeEngine on Avalanche / Fuji.
contract DeployStakeEngine is Script {
    function run() external {
        // Read deployer key and VSP token address from env.
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vspToken = vm.envAddress("VSP_TOKEN_ADDRESS");

        vm.startBroadcast(deployerKey);

        StakeEngine engine = new StakeEngine(vspToken);
        console.log("StakeEngine deployed at:", address(engine));

        vm.stopBroadcast();
    }
}

