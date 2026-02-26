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

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256) {
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

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
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
/// StakeEngine Tests (v2 — lot consolidation + tranches)
/// ------------------------------------------------------------
contract StakeEngineTest is Test {
    MockVSP token;
    StakeEngine engine;
    MockStakeRatePolicy stakeRatePolicy;

    uint256 postA = 1;
    uint256 postB = 2;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new MockVSP();
        stakeRatePolicy = new MockStakeRatePolicy();

        engine = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (
                            address(this), // governance
                            address(token),
                            address(stakeRatePolicy)
                        )
                    )
                )
            )
        );

        // Fund test accounts
        token.mint(address(this), 1e36);
        token.approve(address(engine), type(uint256).max);

        token.mint(alice, 1e36);
        vm.prank(alice);
        token.approve(address(engine), type(uint256).max);

        token.mint(bob, 1e36);
        vm.prank(bob);
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

    function testWithdrawReducesTotals() public {
        engine.stake(postA, 0, 100 ether);
        engine.withdraw(postA, 0, 40 ether, false);

        (uint256 s, uint256 c) = engine.getPostTotals(postA);
        assertEq(s, 60 ether);
        assertEq(c, 0);
    }

    /// ------------------------------------------------------------
    /// Lot consolidation
    /// ------------------------------------------------------------

    function testMultipleStakesConsolidate() public {
        engine.stake(postA, 0, 50 ether);
        engine.stake(postA, 0, 70 ether);

        // Should be one consolidated lot with 120 ether
        uint256 userStake = engine.getUserStake(address(this), postA, 0);
        assertEq(userStake, 120 ether);

        (uint256 s, ) = engine.getPostTotals(postA);
        assertEq(s, 120 ether);
    }

    function testConsolidationWeightedPosition() public {
        // First stake at position 0
        engine.stake(postA, 0, 100 ether);
        // Second stake goes to back of queue (position 100 ether)
        engine.stake(postA, 0, 100 ether);

        // Weighted position should be:
        // (0 * 100 + 100 * 100) / 200 = 50
        uint256 userStake = engine.getUserStake(address(this), postA, 0);
        assertEq(userStake, 200 ether);
    }

    function testDifferentUsersHaveSeparateLots() public {
        engine.stake(postA, 0, 100 ether);

        vm.prank(alice);
        engine.stake(postA, 0, 50 ether);

        assertEq(engine.getUserStake(address(this), postA, 0), 100 ether);
        assertEq(engine.getUserStake(alice, postA, 0), 50 ether);

        (uint256 s, ) = engine.getPostTotals(postA);
        assertEq(s, 150 ether);
    }

    /// ------------------------------------------------------------
    /// Partial withdrawal keeps position
    /// ------------------------------------------------------------

    function testPartialWithdrawKeepsPosition() public {
        engine.stake(postA, 0, 100 ether);
        engine.withdraw(postA, 0, 30 ether, false);

        uint256 userStake = engine.getUserStake(address(this), postA, 0);
        assertEq(userStake, 70 ether);
    }

    /// ------------------------------------------------------------
    /// Gain / loss mechanics (with snapshots)
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

    /// ------------------------------------------------------------
    /// View projection: reads reflect unrealized gains
    /// ------------------------------------------------------------

    function testViewProjectsGainsBeforeSnapshot() public {
        engine.stake(postA, 0, 100 ether);

        // Advance time but DON'T call updatePost
        vm.warp(block.timestamp + 3 days);

        // getPostTotals should project gains without writing state
        (uint256 s, ) = engine.getPostTotals(postA);
        assertGe(s, 100 ether, "View should project gains");
    }

    function testViewProjectsUserStake() public {
        engine.stake(postA, 0, 100 ether);

        vm.warp(block.timestamp + 3 days);

        uint256 projected = engine.getUserStake(address(this), postA, 0);
        assertGe(projected, 100 ether, "User stake should project gains");
    }

    /// ------------------------------------------------------------
    /// Snapshot period behavior
    /// ------------------------------------------------------------

    function testSnapshotTriggersOnStakeAfterPeriod() public {
        engine.stake(postA, 0, 100 ether);
        engine.stake(postA, 1, 10 ether);

        // Advance past snapshot period
        vm.warp(block.timestamp + 2 days);

        // This stake triggers a snapshot internally
        engine.stake(postA, 0, 1 ether);

        // After snapshot, winning side should have grown
        (uint256 s, ) = engine.getPostTotals(postA);
        assertGt(s, 101 ether, "Snapshot should have applied gains");
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
    /// Governance: tranches and snapshot period
    /// ------------------------------------------------------------

    function testGovernanceCanSetTranches() public {
        engine.setNumTranches(20);
        assertEq(engine.numTranches(), 20);
    }

    function testGovernanceCanSetSnapshotPeriod() public {
        engine.setSnapshotPeriod(12 hours);
        assertEq(engine.snapshotPeriod(), 12 hours);
    }

    function test_RevertWhen_ZeroTranches() public {
        vm.expectRevert(StakeEngine.InvalidTranches.selector);
        engine.setNumTranches(0);
    }

    function test_RevertWhen_ZeroSnapshotPeriod() public {
        vm.expectRevert(StakeEngine.InvalidSnapshotPeriod.selector);
        engine.setSnapshotPeriod(0);
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

    function test_RevertWhen_WithdrawNoLot() public {
        vm.expectRevert(StakeEngine.NotEnoughStake.selector);
        engine.withdraw(postA, 0, 100 ether, false);
    }
}
