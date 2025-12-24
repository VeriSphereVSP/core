// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVSPToken
/// @notice Minimal interface for VSP-specific mint/burn permissions.
/// @dev Standard ERC20 methods (name, symbol, decimals, transfer, etc.)
///      are inherited from OpenZeppelin's ERC20 in VSPToken and are not
///      repeated here to avoid multiple-inheritance ambiguities.
interface IVSPToken {
    /// @notice Mint `amount` of VSP to `to`.
    /// @dev Callable only by an authorized minter in VSPToken.
    function mint(address to, uint256 amount) external;

    /// @notice Burn `amount` of VSP from the caller.
    /// @dev Callable only by an authorized burner in VSPToken.
    function burn(uint256 amount) external;

    /// @notice Burn `amount` of VSP from `from`, using allowance.
    /// @dev Callable only by an authorized burner in VSPToken.
    function burnFrom(address from, uint256 amount) external;
}

