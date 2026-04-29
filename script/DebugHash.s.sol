// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

contract DebugHash is Script {
    function run() external view {
        // Compute the type hash
        bytes32 typeHash = keccak256(
            "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)"
        );
        console.log("Type hash:");
        console.logBytes32(typeHash);

        // Compute domain separator manually
        bytes32 domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        address fwd = vm.envAddress("FORWARDER_ADDRESS");
        bytes32 domainSep = keccak256(abi.encode(
            domainTypeHash,
            keccak256("VerisphereForwarder"),
            keccak256("1"),
            uint256(43113),
            fwd
        ));
        console.log("Domain separator:");
        console.logBytes32(domainSep);

        // Compute struct hash for test message
        address from_ = vm.envAddress("BATCH_ADDRESS");
        address to_ = vm.envAddress("VSP_TOKEN");
        bytes32 structHash = keccak256(abi.encode(
            typeHash,
            from_,          // from
            to_,            // to
            uint256(0),     // value
            uint256(1500000), // gas
            uint256(0),     // nonce
            uint256(9999999999), // deadline as uint256 (Solidity pads uint48 to 256)
            keccak256(hex"00") // keccak256(data)
        ));
        console.log("Struct hash:");
        console.logBytes32(structHash);

        // Final EIP-712 hash
        bytes32 finalHash = keccak256(abi.encodePacked(
            "\x19\x01",
            domainSep,
            structHash
        ));
        console.log("Final hash:");
        console.logBytes32(finalHash);

        // Python computed these - compare
        console.log("");
        console.log("Python domain sep: fe6defb73bc1000d28aefbb7cbf4a59b01275c5fdeecef97bc4319635418b76a");
        console.log("Python struct hash: 67e54a1ce33f1421922d8f9441e3fb41fc5e8d61e20bdf5f72e175ce102d05d8");
        console.log("Python final hash:  dc95753043828291aa01ea432184d1c6a735f4096821150a1fa150572f63d389");
    }
}
