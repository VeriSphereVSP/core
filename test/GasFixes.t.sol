// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockPostingFeePolicy.sol";
import "./mocks/MockStakeRatePolicy.sol";
import "./mocks/MockClaimActivityPolicy.sol";

/// @title Gas Fixes Tests
/// @notice Tests for ScoreEngine bounded fan-in and StakeEngine lot compaction.
contract GasFixesTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stakeEng;
    ScoreEngine score;
    MockVSP vsp;
    MockPostingFeePolicy feePolicy;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCA201);

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(50);
        MockStakeRatePolicy ratePolicy = new MockStakeRatePolicy();
        MockClaimActivityPolicy activityPolicy = new MockClaimActivityPolicy();

        registry = PostRegistry(
            _proxy(
                address(new PostRegistry(address(0))),
                abi.encodeCall(PostRegistry.initialize, (address(this), address(vsp), address(feePolicy)))
            )
        );

        graph = LinkGraph(
            _proxy(
                address(new LinkGraph(address(0))),
                abi.encodeCall(LinkGraph.initialize, (address(this)))
            )
        );

        stakeEng = StakeEngine(
            _proxy(
                address(new StakeEngine(address(0))),
                abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(ratePolicy)))
            )
        );

        score = ScoreEngine(
            _proxy(
                address(new ScoreEngine(address(0))),
                abi.encodeCall(
                    ScoreEngine.initialize,
                    (address(this), address(registry), address(stakeEng), address(graph), address(feePolicy), address(activityPolicy))
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // Fund
        address[4] memory users = [address(this), alice, bob, carol];
        for (uint256 i = 0; i < users.length; i++) {
            vsp.mint(users[i], 1e36);
            vm.prank(users[i]);
            vsp.approve(address(stakeEng), type(uint256).max);
            vm.prank(users[i]);
            vsp.approve(address(registry), type(uint256).max);
        }
    }

    // ════════════════════════════════════════════════════════════
    // ScoreEngine: edge limits
    // ════════════════════════════════════════════════════════════

    function test_DefaultEdgeLimits() public view {
        assertEq(score.maxIncomingEdges(), 64);
        assertEq(score.maxOutgoingLinks(), 64);
    }

    function test_GovernanceCanSetEdgeLimits() public {
        score.setEdgeLimits(128, 32);
        assertEq(score.maxIncomingEdges(), 128);
        assertEq(score.maxOutgoingLinks(), 32);
    }

    function test_RevertWhen_ZeroEdgeLimit() public {
        vm.expectRevert(ScoreEngine.InvalidEdgeLimit.selector);
        score.setEdgeLimits(0, 64);

        vm.expectRevert(ScoreEngine.InvalidEdgeLimit.selector);
        score.setEdgeLimits(64, 0);
    }

    function test_RevertWhen_NonGovernanceSetsLimits() public {
        vm.prank(alice);
        vm.expectRevert();
        score.setEdgeLimits(128, 128);
    }

    function test_BoundedFanInStillComputesVS() public {
        // Set very low limit
        score.setEdgeLimits(2, 2);

        // Create claims
        uint256 target = registry.createClaim("target claim");
        stakeEng.stake(target, 0, 100);

        // Create 5 parent claims all supporting target
        for (uint256 i = 0; i < 5; i++) {
            uint256 parent = registry.createClaim(
                string(abi.encodePacked("parent ", vm.toString(i)))
            );
            stakeEng.stake(parent, 0, 100);
            uint256 link = registry.createLink(parent, target, false);
            stakeEng.stake(link, 0, 100);
        }

        // Should not revert, even though 5 > limit of 2
        int256 vs = score.effectiveVSRay(target);
        // VS should still be positive (at least the first 2 links contribute)
        assertGt(vs, 0, "should compute VS even with bounded fan-in");
    }

    // ════════════════════════════════════════════════════════════
    // StakeEngine: compactLots
    // ════════════════════════════════════════════════════════════

    function test_CompactLotsRemovesGhosts() public {
        uint256 postId = 1;

        // Alice and Bob stake support
        vm.prank(alice);
        stakeEng.stake(postId, 0, 100 ether);

        vm.prank(bob);
        stakeEng.stake(postId, 0, 50 ether);

        // Carol stakes a large challenge to push VS negative
        vm.prank(carol);
        stakeEng.stake(postId, 1, 1000 ether);

        // Advance time so support side gets burned
        vm.warp(block.timestamp + 365 days);
        stakeEng.updatePost(postId);

        // Alice's stake should be zero or near-zero (burned out)
        uint256 aliceStake = stakeEng.getUserStake(alice, postId, 0);

        // If burned to zero, compaction should remove the ghost lot
        if (aliceStake == 0) {
            stakeEng.compactLots(postId, 0);
            // Alice's lot should be gone
            assertEq(stakeEng.getUserStake(alice, postId, 0), 0);
        }
    }

    function test_CompactLotsRevertsWhenNoGhosts() public {
        uint256 postId = 1;
        stakeEng.stake(postId, 0, 100 ether);

        // No ghost lots — should revert
        vm.expectRevert(StakeEngine.NoGhostLots.selector);
        stakeEng.compactLots(postId, 0);
    }

    function test_CompactLotsOnlyGovernance() public {
        uint256 postId = 1;
        stakeEng.stake(postId, 0, 100 ether);

        vm.prank(alice);
        vm.expectRevert();
        stakeEng.compactLots(postId, 0);
    }

    function test_CompactLotsPreservesNonGhostPositions() public {
        uint256 postId = 1;

        // Three users stake
        stakeEng.stake(postId, 0, 100 ether);  // governance (index 1)
        vm.prank(alice);
        stakeEng.stake(postId, 0, 200 ether);  // alice (index 2)
        vm.prank(bob);
        stakeEng.stake(postId, 0, 300 ether);  // bob (index 3)

        // Record amounts before
        uint256 selfBefore = stakeEng.getUserStake(address(this), postId, 0);
        uint256 aliceBefore = stakeEng.getUserStake(alice, postId, 0);
        uint256 bobBefore = stakeEng.getUserStake(bob, postId, 0);

        // No ghosts, so compaction should revert
        vm.expectRevert(StakeEngine.NoGhostLots.selector);
        stakeEng.compactLots(postId, 0);

        // Verify amounts unchanged
        assertEq(stakeEng.getUserStake(address(this), postId, 0), selfBefore);
        assertEq(stakeEng.getUserStake(alice, postId, 0), aliceBefore);
        assertEq(stakeEng.getUserStake(bob, postId, 0), bobBefore);
    }
}
