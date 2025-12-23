// SPDX-License-Identifier: MIT
// DEPRECATED: use DeployCore.s.sol instead for full system deployment.

pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/StakeEngine.sol";
import "../src/VSPToken.sol";
import "../src/authority/Authority.sol";

contract DeployStakeEngine is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vsp = vm.envAddress("VSP_TOKEN_ADDRESS");

        vm.startBroadcast(pk);

        StakeEngine engine = new StakeEngine(vsp);
        console.log("StakeEngine deployed at:", address(engine));

        // Grant StakeEngine permissions to mint/burn (must be called by Authority owner)
        Authority auth = VSPToken(vsp).authority();
        auth.setMinter(address(engine), true);
        auth.setBurner(address(engine), true);

        console.log("Granted minter+burner to StakeEngine on Authority:", address(auth));

        vm.stopBroadcast();
    }
}

