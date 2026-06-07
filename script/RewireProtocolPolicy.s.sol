// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

/// @title RewireProtocolPolicy   (marker: patch_deploypath_bundle)
/// @notice DRY encoder for the ATOMIC ProtocolPolicy rewire. Builds the Timelock
///         batch calldata that points all four consumers (StakeEngine, PostRegistry,
///         ScoreEngine, ProtocolViews) at a new ProtocolPolicy in ONE transaction,
///         eliminating the window where some consumers see new and some old.
///
///         Run AFTER the Bundle 12 ceremony makes the Timelock the governance of the
///         four consumers. On Fuji today governance is still the deployer EOA, so
///         this ONLY ENCODES — it never broadcasts. Feed the printed calldata to the
///         Ops Safe (proposer/executor on the Timelock).
///
///         Atomicity: TimelockController.executeBatch runs all four setProtocolPolicy
///         calls with msg.sender == Timelock == governance, so each onlyGovernance
///         check passes.
///
/// Usage (offline; no RPC needed — pure encoding):
///   NEW_PROTOCOL_POLICY=0x<addr> forge script script/RewireProtocolPolicy.s.sol --sig 'run()'
///   (optional) MIN_DELAY=<seconds>   default 172800 (2 days, the prod Timelock minDelay)
contract RewireProtocolPolicy is Script {
    function run() external view {
        address newPolicy = vm.envAddress("NEW_PROTOCOL_POLICY");
        uint256 delay = vm.envOr("MIN_DELAY", uint256(2 days));

        string memory path = string.concat("broadcast/Deploy.s.sol/", vm.toString(block.chainid), "/addresses.json");
        string memory json = vm.readFile(path);
        address timelock = vm.parseJsonAddress(json, ".TimelockController");

        address[] memory targets = new address[](4);
        targets[0] = vm.parseJsonAddress(json, ".StakeEngine");
        targets[1] = vm.parseJsonAddress(json, ".PostRegistry");
        targets[2] = vm.parseJsonAddress(json, ".ScoreEngine");
        targets[3] = vm.parseJsonAddress(json, ".ProtocolViews");

        uint256[] memory values = new uint256[](4); // all zero
        bytes[] memory payloads = new bytes[](4);
        for (uint256 i = 0; i < 4; i++) {
            payloads[i] = abi.encodeWithSignature("setProtocolPolicy(address)", newPolicy);
        }
        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(abi.encodePacked("vsp-rewire-protocolpolicy", newPolicy, block.chainid));

        // OZ TimelockController.hashOperationBatch is pure:
        //   keccak256(abi.encode(targets, values, payloads, predecessor, salt))
        bytes32 opId = keccak256(abi.encode(targets, values, payloads, predecessor, salt));

        bytes memory scheduleData = abi.encodeWithSignature(
            "scheduleBatch(address[],uint256[],bytes[],bytes32,bytes32,uint256)",
            targets,
            values,
            payloads,
            predecessor,
            salt,
            delay
        );
        bytes memory executeData = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)", targets, values, payloads, predecessor, salt
        );

        console.log("=== ProtocolPolicy atomic rewire (Timelock batch, DRY) ===");
        console.log("chainid:", block.chainid);
        console.log("Timelock (send both calls here):", timelock);
        console.log("new ProtocolPolicy:", newPolicy);
        console.log("targets[0] StakeEngine:  ", targets[0]);
        console.log("targets[1] PostRegistry: ", targets[1]);
        console.log("targets[2] ScoreEngine:  ", targets[2]);
        console.log("targets[3] ProtocolViews:", targets[3]);
        console.log("minDelay (s):", delay);
        console.log("operation id:");
        console.logBytes32(opId);
        console.log("--- STEP 1: Safe -> Timelock.scheduleBatch  (calldata) ---");
        console.logBytes(scheduleData);
        console.log("--- STEP 2 (after >= minDelay): Safe -> Timelock.executeBatch  (calldata) ---");
        console.logBytes(executeData);
        console.log("NOTE: valid only AFTER governance is the Timelock; today it is the deployer EOA.");
    }
}
