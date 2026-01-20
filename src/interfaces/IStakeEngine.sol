// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStakeEngine {
    function SIDE_SUPPORT() external pure returns (uint8);
    function SIDE_CHALLENGE() external pure returns (uint8);

    function stake(uint256 postId, uint8 side, uint256 amount) external;
    function withdraw(uint256 postId, uint8 side, uint256 amount, bool lifo) external;
    function updatePost(uint256 postId) external;

    function getPostTotals(uint256 postId)
        external
        view
        returns (uint256 support, uint256 challenge);
}

