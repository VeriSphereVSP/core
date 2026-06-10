// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import "../src/StakeEngine.sol";

/// @title UpgradeStakeEngineOnly
/// @notice Surgical in-place UUPS upgrade of the StakeEngine proxy ONLY.
///         Deploys a fresh StakeEngine impl (embedding the same forwarder the
///         live contracts use) and points the existing proxy at it. No other
///         contract is touched; no proxy address changes; state is preserved.
///
/// @dev    Safe in-place because this change is storage-layout-identical
///         (participationRay clamp only — storage gate confirmed 6/6 vs
///         baseline). The "breaking layout" warning in Upgrade.s.sol refers to
///         the historical v1->v2 migration, NOT this clamp.
///
///         Authorization: _authorizeUpgrade is onlyGovernance; on Fuji
///         governance == deployer EOA. The require() below aborts cleanly if
///         governance was moved (e.g. to the Timelock) so you never send a
///         tx that would revert as NotGovernance.
contract UpgradeStakeEngineOnly is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory jsonFile = vm.readFile("broadcast/Deploy.s.sol/43113/addresses.json");
        address forwarderAddr = vm.envOr("FORWARDER_ADDRESS", _tryParseForwarder(jsonFile));
        address stakeEngineProxy = vm.parseJsonAddress(jsonFile, ".StakeEngine");

        address currentGov = StakeEngine(stakeEngineProxy).governance();
        address currentPolicy = address(StakeEngine(stakeEngineProxy).protocolPolicy());

        console.log("=== StakeEngine-only upgrade ===");
        console.log("Deployer:        ", deployer);
        console.log("Forwarder:       ", forwarderAddr);
        console.log("StakeEngine proxy:", stakeEngineProxy);
        console.log("governance():    ", currentGov);
        console.log("protocolPolicy():", currentPolicy);

        require(
            currentGov == deployer,
            "governance() != deployer EOA -- upgrade must be routed via the governance holder (abort)"
        );

        vm.startBroadcast(pk);

        StakeEngine newImpl = new StakeEngine(forwarderAddr);
        UUPSUpgradeable(stakeEngineProxy).upgradeToAndCall(address(newImpl), bytes(""));

        vm.stopBroadcast();

        console.log("New StakeEngine impl:", address(newImpl));
        console.log("Upgrade complete. Proxy unchanged:", stakeEngineProxy);
        console.log("protocolPolicy() still:", address(StakeEngine(stakeEngineProxy).protocolPolicy()));
    }

    function _tryParseForwarder(string memory json) internal view returns (address) {
        try vm.parseJsonAddress(json, ".Forwarder") returns (address f) {
            return f;
        } catch {
            return address(0);
        }
    }
}
