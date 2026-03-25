// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

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

/// @title Deploy
/// @notice Deploys the full VeriSphere protocol.
///         Environment-aware: if PRODUCTION=true, deploys a TimelockController
///         and initiates two-step ownership transfer from deployer to timelock.
///         Otherwise, deployer EOA retains ownership for fast iteration.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool isProduction = vm.envOr("PRODUCTION", false);

        vm.startBroadcast(pk);

        // In dev, gov = deployer. In prod, gov = TimelockController (deployed below).
        address gov = deployer;

        Authority authority = new Authority(gov);

        // Forwarder is deployed separately (see app/contracts/VerisphereForwarder.sol).
        // Pass its address via FORWARDER_ADDRESS env var.
        // Use address(0) if no forwarder is needed (direct wallet interaction only).
        address forwarder = vm.envOr("FORWARDER_ADDRESS", address(0));

        // Deploy TimelockController for policy contracts (and Authority in prod)
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;

        TimelockController timelock = new TimelockController(
            isProduction ? 2 days : 0, // minDelay: 2 days in prod, 0 in dev
            proposers,
            executors,
            deployer // admin — can be renounced later in prod
        );

        PostingFeePolicy postingFeePolicy = new PostingFeePolicy(
            address(timelock),
            1e18
        );
        ClaimActivityPolicy activityPolicy = new ClaimActivityPolicy(
            address(timelock),
            1e18
        );
        StakeRatePolicy stakeRatePolicy = new StakeRatePolicy(
            address(timelock),
            0,
            1e18
        );

        VSPToken tokenImpl = new VSPToken();
        ERC1967Proxy tokenProxy = new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(VSPToken.initialize, (address(authority)))
        );
        VSPToken token = VSPToken(address(tokenProxy));

        authority.setMinter(gov, true);
        authority.setBurner(gov, true);

        // Implementation contracts take forwarder in constructor (OZ 5.5 immutable pattern)
        StakeEngine stakeImpl = new StakeEngine(forwarder);
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

        PostRegistry registryImpl = new PostRegistry(forwarder);
        ERC1967Proxy registryProxy = new ERC1967Proxy(
            address(registryImpl),
            abi.encodeCall(
                PostRegistry.initialize,
                (gov, address(token), address(postingFeePolicy))
            )
        );
        PostRegistry registry = PostRegistry(address(registryProxy));

        // PostRegistry needs burner role to burn posting fees
        authority.setBurner(address(registry), true);

        LinkGraph graphImpl = new LinkGraph(forwarder);
        ERC1967Proxy graphProxy = new ERC1967Proxy(
            address(graphImpl),
            abi.encodeCall(LinkGraph.initialize, (gov))
        );
        LinkGraph graph = LinkGraph(address(graphProxy));

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        ScoreEngine scoreImpl = new ScoreEngine(forwarder);
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

        ProtocolViews viewsImpl = new ProtocolViews(forwarder);
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

        // ── Production: initiate ownership transfer to timelock ──
        if (isProduction) {
            // Propose timelock as new Authority owner.
            // The timelock must call authority.acceptOwner() to complete.
            authority.proposeOwner(address(timelock));

            console.log("");
            console.log("PRODUCTION MODE: Ownership transfer initiated.");
            console.log("TimelockController:", address(timelock));
            console.log("Authority pending owner:", address(timelock));
            console.log("");
            console.log(
                "NEXT STEP: Schedule and execute authority.acceptOwner()"
            );
            console.log(
                "via the TimelockController to complete ownership transfer."
            );
        }

        vm.stopBroadcast();

        string memory json = string.concat(
            '{"Authority":"',
            vm.toString(address(authority)),

            '","TimelockController":"',
            vm.toString(address(timelock)),
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
