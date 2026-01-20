// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/StakeEngine.sol";
import "../src/interfaces/IVSPToken.sol";

/// Mock VSP Token — full IVSPToken + IERC20 compliance
contract MockVSP is IVSPToken {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    uint256 public totalSupplyStored;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
        totalSupplyStored += amount;
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyStored;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "insufficient");
        balances[msg.sender] -= amount;
        balances[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(allowances[from][msg.sender] >= amount, "allowance");
        require(balances[from] >= amount, "insufficient");

        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        balances[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        require(balances[msg.sender] >= amount, "burn");
        balances[msg.sender] -= amount;
        totalSupplyStored -= amount;
    }

    function burnFrom(address from, uint256 amount) external {  // Removed override (not needed in mock)
        require(allowances[from][msg.sender] >= amount, "allowance");
        require(balances[from] >= amount, "burn");

        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        totalSupplyStored -= amount;
    }
}

/// StakeEngine Tests
contract StakeEngineTest is Test {
    MockVSP token;
    StakeEngine engine;

    uint256 postId = 1;

    function setUp() public {
        token = new MockVSP();

        engine = new StakeEngine(address(token));

        token.mint(address(this), 1e36);
        token.approve(address(engine), type(uint256).max);
    }

    function testStakeIncreasesTotals() public {
        engine.stake(postId, 0, 100 ether);
        engine.stake(postId, 1, 30 ether);

        (uint256 s, uint256 c) = engine.getPostTotals(postId);
        assertEq(s, 100 ether);
        assertEq(c, 30 ether);
    }

    function testWithdrawReducesTotals() public {
        engine.stake(postId, 0, 100 ether);
        engine.withdraw(postId, 0, 40 ether, false); // FIFO

        (uint256 s, uint256 c) = engine.getPostTotals(postId);
        assertEq(s, 60 ether);
        assertEq(c, 0);
    }

    function testWithdrawLIFO() public {
        engine.stake(postId, 0, 50 ether);
        engine.stake(postId, 0, 70 ether);

        engine.withdraw(postId, 0, 60 ether, true); // LIFO

        (uint256 s,) = engine.getPostTotals(postId);
        assertEq(s, 60 ether);
    }

    function testEpochGrowthNoDecreaseWhenWinning() public {
        uint256 bigStake = 1e30;

        engine.stake(postId, 0, bigStake);

        vm.warp(block.timestamp + 2 days);

        engine.updatePost(postId);

        (uint256 s, uint256 c) = engine.getPostTotals(postId);
        assertEq(c, 0);
        assertGe(s, bigStake);
    }

    function test_RevertWhen_InvalidSideStake() public {
        vm.expectRevert(StakeEngine.InvalidSide.selector);
        engine.stake(postId, 3, 100);
    }

    function test_RevertWhen_InvalidSideWithdraw() public {
        vm.expectRevert(StakeEngine.InvalidSide.selector);
        engine.withdraw(postId, 2, 100, false);
    }

    function test_RevertWhen_ZeroStake() public {
        vm.expectRevert(StakeEngine.AmountZero.selector);
        engine.stake(postId, 0, 0);
    }

    function test_RevertWhen_ZeroWithdraw() public {
        vm.expectRevert(StakeEngine.AmountZero.selector);
        engine.withdraw(postId, 0, 0, false);
    }

    function test_RevertWhen_WithdrawTooMuch() public {
        engine.stake(postId, 0, 100 ether);

        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(postId, 0, 200 ether, false);
    }
}
