// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/StakeEngine.sol";

contract DeployStakeEngine is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vsp = vm.envAddress("VSP_TOKEN_ADDRESS");

        vm.startBroadcast(pk);

        StakeEngine engine = new StakeEngine(vsp);
        console.log("StakeEngine deployed at:", address(engine));

        vm.stopBroadcast();
    }
}

