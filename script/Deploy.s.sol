// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/authority/Authority.sol";
import "../src/VSPToken.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";

import "../src/governance/PostingFeePolicy.sol";
import "../src/governance/ClaimActivityPolicy.sol";
import "../src/governance/StakeRatePolicy.sol";

contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        // Governance
        address gov = deployer;

        Authority authority = new Authority(gov);

        PostingFeePolicy postingFeePolicy = new PostingFeePolicy(gov, 1e18);
        ClaimActivityPolicy activityPolicy = new ClaimActivityPolicy(gov, 1e18);
        StakeRatePolicy stakeRatePolicy = new StakeRatePolicy(gov, 0, 50e16);

        VSPToken token = new VSPToken(address(authority));

        authority.setMinter(gov, true);
        authority.setBurner(gov, true);

        // --- StakeEngine proxy ---
        StakeEngine stakeImpl = new StakeEngine();
        ERC1967Proxy stakeProxy = new ERC1967Proxy(
            address(stakeImpl),
            abi.encodeCall(
                StakeEngine.initialize,
                (gov, address(token), address(stakeRatePolicy))
            )
        );
        StakeEngine stake = StakeEngine(address(stakeProxy));

        authority.setMinter(address(stake), true);
        authority.setBurner(address(stake), true);

        // --- PostRegistry ---
        PostRegistry registryImpl = new PostRegistry();
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                PostRegistry.initialize,
                (gov, address(token), address(postingFeePolicy))
            )
        );
        PostRegistry registry = PostRegistry(address(registryProxy));

        // --- LinkGraph ---
        LinkGraph graphImpl = new LinkGraph();
        ERC1967Proxy graphProxy = new ERC1967Proxy(
            address(graphImpl),
            abi.encodeCall(
                LinkGraph.initialize,
                (gov)
            )
        );
        LinkGraph graph = LinkGraph(address(graphProxy));

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // --- ScoreEngine ---
        ScoreEngine scoreImpl = new ScoreEngine();
        ERC1967Proxy scoreProxy = new ERC1967Proxy(
            address(scoreImpl),
            abi.encodeCall(
                ScoreEngine.initialize,
                (
                    gov,
                    address(registry),
                    address(stake),
                    address(graph),
                    address(postingFeePolicy),
                    address(activityPolicy)
                )
            )
        );
        ScoreEngine score = ScoreEngine(address(scoreProxy));

        // --- ProtocolViews ---
        ProtocolViews viewsImpl = new ProtocolViews();
        ERC1967Proxy viewsProxy = new ERC1967Proxy(
            address(viewsImpl),
            abi.encodeCall(
                ProtocolViews.initialize,
                (
                    gov,
                    address(registry),
                    address(stake),
                    address(graph),
                    address(score),
                    address(postingFeePolicy)
                )
            )
        );

        vm.stopBroadcast();
    }
}

