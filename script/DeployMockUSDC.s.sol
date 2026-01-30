// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/MockUSDC.sol";

contract DeployMockUSDC is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        // Hardcode mm wallet as owner (or load from env)
        // address mmOwner = 0x744a16c4Fe6B618E29D5Cb05C5a9cBa72175e60a;

        address mmOwner = vm.envAddress("MOCK_USDC_OWNER"); // optional

        MockUSDC usdc = new MockUSDC(mmOwner);

        vm.stopBroadcast();

        console.log("MockUSDC deployed to:", address(usdc));
        console.log("Owner set to (mm wallet):", mmOwner);
    }
}
