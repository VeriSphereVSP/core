// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract IdleDecay {
    mapping(address => uint256) public lastActivity;
    uint256 public idleDecayRateBps = 100; // 1% yearly (example)
    uint256 constant YEAR = 365 days;

    event IdleDecayApplied(address indexed user, uint256 decayed);

    function _applyDecay(address user) internal returns (uint256 decayed) {
        uint256 last = lastActivity[user];
        if (last == 0) {
            lastActivity[user] = block.timestamp;
            return 0;
        }

        uint256 elapsed = block.timestamp - last;
        uint256 balance = _balanceOf(user);
        uint256 rate = idleDecayRateBps;

        decayed = (balance * rate * elapsed) / (YEAR * 10_000);

        if (decayed > 0) {
            _burn(user, decayed);
            emit IdleDecayApplied(user, decayed);
        }

        lastActivity[user] = block.timestamp;
    }

    // Abstract functions implemented by VSPToken
    function _burn(address from, uint256 amount) internal virtual;
    function _balanceOf(address user) internal view virtual returns (uint256);
}
