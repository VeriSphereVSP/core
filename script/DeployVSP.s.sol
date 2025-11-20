// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/VSPToken.sol";

contract DeployVSP is Script {
    function run() external {
        uint256 deployer = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployer);

        VSPToken token = new VSPToken(vm.addr(deployer));

        console.log("VSP deployed:", address(token));

        vm.stopBroadcast();
    }
}
