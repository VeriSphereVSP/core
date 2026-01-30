// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";
import "../src/governance/PostingFeePolicy.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockStakeRatePolicy.sol";
import "./mocks/MockClaimActivityPolicy.sol";

contract EconomicInvariantsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views;

    MockVSP vsp;
    PostingFeePolicy feePolicy;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new PostingFeePolicy(address(0), 100);

        MockStakeRatePolicy stakeRatePolicy = new MockStakeRatePolicy();
        MockClaimActivityPolicy activityPolicy = new MockClaimActivityPolicy();

        registry = PostRegistry(
            _proxy(
                address(new PostRegistry()),
                abi.encodeCall(
                    PostRegistry.initialize,
                    (address(this), address(vsp), address(feePolicy))
                )
            )
        );

        graph = LinkGraph(
            _proxy(
                address(new LinkGraph()),
                abi.encodeCall(LinkGraph.initialize, (address(this)))
            )
        );

        stake = StakeEngine(
            _proxy(
                address(new StakeEngine()),
                abi.encodeCall(
                    StakeEngine.initialize,
                    (address(this), address(vsp), address(stakeRatePolicy))
                )
            )
        );

        score = ScoreEngine(
            _proxy(
                address(new ScoreEngine()),
                abi.encodeCall(
                    ScoreEngine.initialize,
                    (
                        address(this),
                        address(registry),
                        address(stake),
                        address(graph),
                        address(feePolicy),
                        address(activityPolicy)
                    )
                )
            )
        );

        views = ProtocolViews(
            _proxy(
                address(new ProtocolViews()),
                abi.encodeCall(
                    ProtocolViews.initialize,
                    (
                        address(this),
                        address(registry),
                        address(stake),
                        address(graph),
                        address(score),
                        address(feePolicy)
                    )
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp.mint(address(this), 1_000_000 ether);
        vsp.mint(address(registry), 1_000_000 ether);
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

