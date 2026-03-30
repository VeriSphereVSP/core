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

contract ScoreEngineTest is Test {
    PostRegistry registry;
    StakeEngine stake;
    LinkGraph graph;
    ScoreEngine score;

    MockVSP vsp;
    MockPostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(50);

        MockStakeRatePolicy stakeRatePolicy = new MockStakeRatePolicy();
        MockClaimActivityPolicy activityPolicy = new MockClaimActivityPolicy();

        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(
                        PostRegistry.initialize,
                        (address(this), address(vsp), address(feePolicy))
                    )
                )
            )
        );

        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))),
                    abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        stake = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine(address(0))),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (address(this), address(vsp), address(stakeRatePolicy))
                    )
                )
            )
        );

        score = ScoreEngine(
            address(
                new ERC1967Proxy(
                    address(new ScoreEngine(address(0))),
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
            )
        );

        vsp.mint(address(this), 1e30);
        vsp.mint(address(registry), 1e30);
        vsp.approve(address(registry), type(uint256).max);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_VS_BelowFee_BaseStillComputes() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 49);
        // baseVSRay does NOT check activity — it always computes from stake.
        assertEq(score.baseVSRay(c), 1e18, "baseVS computes regardless of activity");
    }

    function test_VS_NonZero_AtFee() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 50);
        assertEq(score.baseVSRay(c), 1e18);
    }
}
