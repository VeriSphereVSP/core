// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/StakeEngine.sol";
import "../src/interfaces/IVSPToken.sol";

import "./mocks/MockStakeRatePolicy.sol";

/// ------------------------------------------------------------
/// Mock VSP Token — full IVSPToken + IERC20 compliance
/// ------------------------------------------------------------
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

    function burnFrom(address from, uint256 amount) external {
        require(allowances[from][msg.sender] >= amount, "allowance");
        require(balances[from] >= amount, "burn");

        allowances[from][msg.sender] -= amount;
        balances[from] -= amount;
        totalSupplyStored -= amount;
    }
}

/// ------------------------------------------------------------
/// StakeEngine Tests
/// ------------------------------------------------------------
contract StakeEngineTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockStakeRatePolicy stakeRatePolicy;

    uint256 postA = 1;
    uint256 postB = 2;

    function setUp() public {
        token = new MockVSP();
        stakeRatePolicy = new MockStakeRatePolicy();

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine()),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (
                            address(this),            // governance
                            address(token),
                            address(stakeRatePolicy)
                        )
                    )
                )
            )
        );

        token.mint(address(this), 1e36);
        token.approve(address(engine), type(uint256).max);
    }

    /// ------------------------------------------------------------
    /// Basic stake / withdraw behavior
    /// ------------------------------------------------------------

    function testStakeIncreasesTotals() public {
        engine.stake(postA, 0, 100 ether);
        engine.stake(postA, 1, 30 ether);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertEq(s, 100 ether);
        assertEq(c, 30 ether);
    }

    function testWithdrawReducesTotalsFIFO() public {
        engine.stake(postA, 0, 100 ether);
        engine.withdraw(postA, 0, 40 ether, false);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertEq(s, 60 ether);
        assertEq(c, 0);
    }

    function testWithdrawLIFO() public {
        engine.stake(postA, 0, 50 ether);
        engine.stake(postA, 0, 70 ether);

        engine.withdraw(postA, 0, 60 ether, true);

        (uint256 s,) = engine.getPostTotals(postA);
        assertEq(s, 60 ether);
    }

    /// ------------------------------------------------------------
    /// Gain / loss mechanics (weak invariants, single epoch)
    /// ------------------------------------------------------------

    function testWinningSideNeverDecreases() public {
        uint256 stakeAmount = 1e30;

        engine.stake(postA, 0, stakeAmount);

        vm.warp(block.timestamp + 3 days);
        engine.updatePost(postA);

        (uint256 support, uint256 challenge) = engine.getPostTotals(postA);

        assertEq(challenge, 0);
        assertGe(support, stakeAmount);
    }

    function testLosingSideNeverIncreases() public {
        engine.stake(postA, 0, 100 ether);
        engine.stake(postA, 1, 10 ether);

        uint256 supplyBefore = token.totalSupply();

        vm.warp(block.timestamp + 2 days);
        engine.updatePost(postA);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);

        assertGe(s, 100 ether);
        assertLe(c, 10 ether);
        assertLe(token.totalSupply(), supplyBefore);
    }

    function testNoGrowthWhenBalanced() public {
        engine.stake(postA, 0, 50 ether);
        engine.stake(postA, 1, 50 ether);

        vm.warp(block.timestamp + 3 days);
        engine.updatePost(postA);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);

        assertEq(s, 50 ether);
        assertEq(c, 50 ether);
    }

    function testLargeStakeGrowsAtLeastAsMuchAsSmall() public {
        engine.stake(postA, 0, 1e30);
        engine.stake(postB, 0, 10 ether);

        vm.warp(block.timestamp + 5 days);
        engine.updatePost(postA);
        engine.updatePost(postB);

        (uint256 big,) = engine.getPostTotals(postA);
        (uint256 small,) = engine.getPostTotals(postB);

        assertGe(big - 1e30, small - 10 ether);
    }

    /// ------------------------------------------------------------
    /// sMax behavior
    /// ------------------------------------------------------------

    function testSMaxNeverIncreasesWithoutNewStake() public {
        engine.stake(postA, 0, 100 ether);
        uint256 initial = engine.sMax();

        vm.warp(block.timestamp + 10 days);
        engine.updatePost(postA);

        uint256 afterDecay = engine.sMax();
        assertLe(afterDecay, initial);
    }

    function testSMaxJumpsToAtLeastNewMaximum() public {
        engine.stake(postA, 0, 100 ether);

        vm.warp(block.timestamp + 10 days);
        engine.updatePost(postA);

        engine.stake(postB, 0, 300 ether);
        assertGe(engine.sMax(), 300 ether);
    }

    /// ------------------------------------------------------------
    /// Reverts
    /// ------------------------------------------------------------

    function test_RevertWhen_InvalidSideStake() public {
        vm.expectRevert(StakeEngine.InvalidSide.selector);
        engine.stake(postA, 3, 100);
    }

    function test_RevertWhen_InvalidSideWithdraw() public {
        vm.expectRevert(StakeEngine.InvalidSide.selector);
        engine.withdraw(postA, 2, 100, false);
    }

    function test_RevertWhen_ZeroStake() public {
        vm.expectRevert(StakeEngine.AmountZero.selector);
        engine.stake(postA, 0, 0);
    }

    function test_RevertWhen_ZeroWithdraw() public {
        vm.expectRevert(StakeEngine.AmountZero.selector);
        engine.withdraw(postA, 0, 0, false);
    }

    function test_RevertWhen_WithdrawTooMuch() public {
        engine.stake(postA, 0, 100 ether);

        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(postA, 0, 200 ether, false);
    }
}

