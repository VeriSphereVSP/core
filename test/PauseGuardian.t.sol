// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/StakeEngine.sol";
import "../src/LinkGraph.sol";
import "../src/governance/GovernedUpgradeable.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockPostingFeePolicy.sol";
import "./mocks/MockStakeRatePolicy.sol";

contract PauseGuardianTest is Test {
    PostRegistry pr;
    StakeEngine se;
    LinkGraph lg;
    MockVSP vsp;
    MockPostingFeePolicy feePolicy;
    MockStakeRatePolicy ratePolicy;

    address governance = address(0xA110);
    address guardian   = address(0xB220);
    address user       = address(0xCAFE);
    address attacker   = address(0xDEAD);

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(0);  // 0 fee for tests
        ratePolicy = new MockStakeRatePolicy();

        pr = PostRegistry(_proxy(
            address(new PostRegistry(address(0))),
            abi.encodeCall(PostRegistry.initialize,
                (governance, address(vsp), address(feePolicy)))
        ));

        lg = LinkGraph(_proxy(
            address(new LinkGraph(address(0))),
            abi.encodeCall(LinkGraph.initialize, (governance))
        ));

        se = StakeEngine(_proxy(
            address(new StakeEngine(address(0))),
            abi.encodeCall(StakeEngine.initialize,
                (governance, address(vsp), address(ratePolicy)))
        ));

        // Wire LinkGraph <-> PostRegistry both directions.
        vm.startPrank(governance);
        pr.setLinkGraph(address(lg));
        lg.setRegistry(address(pr));
        vm.stopPrank();

        // Initialize V2: governance sets Guardian on both contracts.
        vm.prank(governance);
        pr.initializeV2(guardian);
        vm.prank(governance);
        se.initializeV2(guardian);

        // Mint user some VSP for stake tests.
        vsp.mint(user, 1000 ether);

        // User approves StakeEngine to pull VSP for staking.
        vm.prank(user);
        vsp.approve(address(se), type(uint256).max);
    }

    // ─── 1: Guardian can pause PostRegistry ──────────────────────────
    function testGuardianCanPausePR() public {
        vm.prank(guardian);
        pr.pause();
        assertTrue(pr.paused());
    }

    // ─── 2: Governance can pause without being Guardian ──────────────
    function testGovernanceCanPausePR() public {
        vm.prank(governance);
        pr.pause();
        assertTrue(pr.paused());
    }

    // ─── 3: Random caller cannot pause ───────────────────────────────
    function testRandomCannotPausePR() public {
        vm.prank(attacker);
        vm.expectRevert(PostRegistry.NotGuardianOrGovernance.selector);
        pr.pause();
    }

    // ─── 4: Guardian CANNOT unpause ──────────────────────────────────
    function testGuardianCannotUnpausePR() public {
        vm.prank(guardian);
        pr.pause();

        vm.prank(guardian);
        vm.expectRevert(GovernedUpgradeable.NotGovernance.selector);
        pr.unpause();

        // Sanity: governance can.
        vm.prank(governance);
        pr.unpause();
        assertFalse(pr.paused());
    }

    // ─── 5: Only governance can change Guardian ──────────────────────
    function testOnlyGovernanceCanChangeGuardian() public {
        address newGuardian = address(0xB221);

        vm.prank(guardian);
        vm.expectRevert(GovernedUpgradeable.NotGovernance.selector);
        pr.setGuardian(newGuardian);

        vm.prank(governance);
        pr.setGuardian(newGuardian);
        assertEq(pr.guardian(), newGuardian);
    }

    // ─── 6: createClaim reverts when paused ──────────────────────────
    function testCreateClaimRevertsWhenPaused() public {
        vm.prank(guardian);
        pr.pause();

        vm.prank(user);
        vm.expectRevert(PostRegistry.WhenPaused.selector);
        pr.createClaim("hello world");
    }

    // ─── 7: createLink reverts when paused ───────────────────────────
    function testCreateLinkRevertsWhenPaused() public {
        // Create two unpaused claims first so we can link them.
        vm.prank(user);
        uint256 a = pr.createClaim("claim a");
        vm.prank(user);
        uint256 b = pr.createClaim("claim b");

        vm.prank(guardian);
        pr.pause();

        vm.prank(user);
        vm.expectRevert(PostRegistry.WhenPaused.selector);
        pr.createLink(a, b, false);
    }

    // ─── 8: Governance functions still work while paused ─────────────
    function testGovernanceWorksWhenPaused() public {
        vm.prank(guardian);
        pr.pause();

        // setGuardian should still succeed (governance-only function).
        vm.prank(governance);
        pr.setGuardian(address(0xB230));
        assertEq(pr.guardian(), address(0xB230));
    }

    // ─── 9: After unpause, createClaim works again ───────────────────
    function testCreateClaimWorksAfterUnpause() public {
        vm.prank(guardian);
        pr.pause();

        vm.prank(governance);
        pr.unpause();

        vm.prank(user);
        uint256 id = pr.createClaim("post-unpause claim");
        assertGt(id, 0);
    }

    // ─── 10: StakeEngine.stake reverts when paused ───────────────────
    function testStakeRevertsWhenPaused() public {
        vm.prank(user);
        uint256 a = pr.createClaim("stakable claim");

        vm.prank(guardian);
        se.pause();

        vm.prank(user);
        vm.expectRevert(StakeEngine.WhenPaused.selector);
        se.stake(a, 0, 1 ether);
    }

    // ─── 11: setStake reverts when paused ────────────────────────────
    function testSetStakeRevertsWhenPaused() public {
        vm.prank(user);
        uint256 a = pr.createClaim("stakable claim 2");

        vm.prank(guardian);
        se.pause();

        vm.prank(user);
        vm.expectRevert(StakeEngine.WhenPaused.selector);
        se.setStake(a, int256(1 ether));
    }

    // ─── 12: withdraw works while paused (users always exit) ─────────
    function testWithdrawWorksWhenPaused() public {
        vm.prank(user);
        uint256 a = pr.createClaim("stakable claim 3");

        vm.prank(user);
        se.stake(a, 0, 5 ether);

        vm.prank(guardian);
        se.pause();

        // Withdraw should succeed even while paused.
        vm.prank(user);
        se.withdraw(a, 0, 5 ether, false);
    }

    // ─── 13: updatePost works while paused ───────────────────────────
    function testUpdatePostWorksWhenPaused() public {
        vm.prank(user);
        uint256 a = pr.createClaim("stakable claim 4");

        vm.prank(user);
        se.stake(a, 0, 1 ether);

        vm.prank(guardian);
        se.pause();

        // updatePost is a public-good operation; should work paused.
        vm.prank(user);
        se.updatePost(a);
    }

    // ─── 14: initializeV2 callable only once ─────────────────────────
    function testInitV2OnlyOnce() public {
        vm.prank(governance);
        vm.expectRevert(PostRegistry.AlreadyInitializedV2.selector);
        pr.initializeV2(address(0xB221));

        vm.prank(governance);
        vm.expectRevert(StakeEngine.AlreadyInitializedV2.selector);
        se.initializeV2(address(0xB221));
    }

    // ─── 15: initializeV2 callable only by governance ───────────────
    function testInitV2OnlyGovernance() public {
        // Fresh deploy of a fresh proxy to test pre-initV2 access control.
        PostRegistry pr2 = PostRegistry(_proxy(
            address(new PostRegistry(address(0))),
            abi.encodeCall(PostRegistry.initialize,
                (governance, address(vsp), address(feePolicy)))
        ));

        vm.prank(attacker);
        vm.expectRevert(GovernedUpgradeable.NotGovernance.selector);
        pr2.initializeV2(guardian);

        // Governance succeeds.
        vm.prank(governance);
        pr2.initializeV2(guardian);
        assertEq(pr2.guardian(), guardian);
    }
}
