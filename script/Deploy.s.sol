// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/authority/Authority.sol";
import "../src/VerisphereForwarder.sol";
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

        address gov = deployer;

        Authority authority = new Authority(gov);

        // Deploy trusted forwarder first — its address is needed by impl constructors
        VerisphereForwarder forwarder = new VerisphereForwarder();

        PostingFeePolicy postingFeePolicy = new PostingFeePolicy(gov, 1e18);
        ClaimActivityPolicy activityPolicy = new ClaimActivityPolicy(gov, 1e18);
        StakeRatePolicy stakeRatePolicy = new StakeRatePolicy(gov, 0, 50e16);

        VSPToken token = new VSPToken(address(authority));

        authority.setMinter(gov, true);
        authority.setBurner(gov, true);

        // Implementation contracts take forwarder in constructor (OZ 5.5 immutable pattern)
        // initialize() uses original arg counts (no forwarder arg)
        StakeEngine stakeImpl = new StakeEngine(address(forwarder));
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

        PostRegistry registryImpl = new PostRegistry(address(forwarder));
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                PostRegistry.initialize,
                (gov, address(token), address(postingFeePolicy))
            )
        );
        PostRegistry registry = PostRegistry(address(registryProxy));

        authority.setBurner(address(registry), true);

        LinkGraph graphImpl = new LinkGraph(address(forwarder));
        ERC1967Proxy graphProxy = new ERC1967Proxy(
            address(graphImpl),
            abi.encodeCall(LinkGraph.initialize, (gov))
        );
        LinkGraph graph = LinkGraph(address(graphProxy));

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        ScoreEngine scoreImpl = new ScoreEngine(address(forwarder));
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

        ProtocolViews viewsImpl = new ProtocolViews(address(forwarder));
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

        vm.label(address(registry), "PostRegistry");
        vm.label(address(graph), "LinkGraph");
        vm.label(address(stake), "StakeEngine");
        vm.label(address(score), "ScoreEngine");
        vm.label(address(viewsProxy), "ProtocolViews");
        vm.label(address(forwarder), "Forwarder");

        vm.stopBroadcast();

        string memory json = string.concat(
            '{"Authority":"',
            vm.toString(address(authority)),
            '","Forwarder":"',
            vm.toString(address(forwarder)),
            '","VSPToken":"',
            vm.toString(address(token)),
            '","PostRegistry":"',
            vm.toString(address(registry)),
            '","LinkGraph":"',
            vm.toString(address(graph)),
            '","StakeEngine":"',
            vm.toString(address(stake)),
            '","ScoreEngine":"',
            vm.toString(address(score)),
            '","ProtocolViews":"',
            vm.toString(address(viewsProxy)),
            '"}'
        );

        vm.writeFile("broadcast/Deploy.s.sol/43113/addresses.json", json);
    }
}
