// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

/// @title VerisphereForwarder
/// @notice Trusted forwarder for gasless meta-transactions (ERC-2771).
contract VerisphereForwarder is ERC2771Forwarder {
    constructor() ERC2771Forwarder("VerisphereForwarder") {}
}
