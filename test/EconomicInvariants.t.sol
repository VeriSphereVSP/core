// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";
import "../src/governance/PostingFeePolicy.sol";
import "./mocks/MockVSP.sol";

contract EconomicInvariantsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views;

    MockVSP vsp;
    PostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new PostingFeePolicy(address(0), 100);

        registry = new PostRegistry(address(vsp), address(feePolicy));
        graph = new LinkGraph(address(this));
        stake = new StakeEngine(address(vsp));

        score = new ScoreEngine(
            address(registry),
            address(stake),
            address(graph),
            address(feePolicy)
        );

        views = new ProtocolViews(
            address(registry),
            address(stake),
            address(graph),
            address(score),
            address(feePolicy)
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // Mint enough for fees + stakes
        vsp.mint(address(this), 1_000_000 ether);
        vsp.mint(address(registry), 1_000_000 ether); // ← FIXED: Mint to registry so burn succeeds
        vsp.approve(address(registry), type(uint256).max);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_VSActivatesAtPostingFee() public {
        uint256 c = registry.createClaim("Claim");

        stake.stake(c, 0, 100);

        assertTrue(views.isActive(c));
        assertEq(views.getBaseVSRay(c), 1e18);
    }

    function test_VSZeroBelowPostingFee() public {
        uint256 c = registry.createClaim("Claim");

        stake.stake(c, 0, 99);

        assertEq(views.getBaseVSRay(c), 0);
        assertEq(views.getEffectiveVSRay(c), 0);
        assertFalse(views.isActive(c));
    }
}
