// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IVSPToken
/// @notice Minimal interface for the VSP ERC20 used across the protocol.
interface IVSPToken {
    // ------------------------------------------------------------------------
    // ERC-20
    // ------------------------------------------------------------------------

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external pure returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function transfer(address to, uint256 amount) external returns (bool);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    // ------------------------------------------------------------------------
    // VSP-specific mint/burn hooks
    // ------------------------------------------------------------------------

    /// @notice Mint new VSP to `to`.
    /// @dev Restricted by Authority (minter role).
    function mint(address to, uint256 amount) external;

    /// @notice Burn VSP from the caller's balance.
    /// @dev Restricted by Authority (burner role).
    function burn(uint256 amount) external;

    /// @notice Burn VSP from `from` using allowance.
    /// @dev Restricted by Authority (burner role) and allowance.
    function burnFrom(address from, uint256 amount) external;
}


