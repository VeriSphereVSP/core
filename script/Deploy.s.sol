    // SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/StdJson.sol";

import "../src/authority/Authority.sol";
import "../src/VSPToken.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";
import "../src/governance/PostingFeePolicy.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

contract Deploy is Script {
    using stdJson for string;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory env = vm.envOr("DEPLOY_ENV", string("dev"));

        vm.startBroadcast(pk);

        address deployer = msg.sender;

        // Governance
        address gov = keccak256(bytes(env)) == keccak256("dev") ? deployer : vm.envAddress("GOVERNANCE_MULTISIG");

        Authority authority = new Authority(gov);

        TimelockController timelock = new TimelockController(2 days, _arr(gov), _arr(gov), address(0));

        PostingFeePolicy feePolicy = new PostingFeePolicy(address(timelock), 1e18); // 1 VSP posting fee

        // Token
        VSPToken token = new VSPToken(address(authority));
        authority.setMinter(gov, true);
        authority.setBurner(gov, true);

        // Core protocol
        PostRegistry registry = new PostRegistry(address(token), address(feePolicy));

        LinkGraph graph = new LinkGraph(gov);
        StakeEngine stake = new StakeEngine(address(token));
        ScoreEngine score = new ScoreEngine(address(registry), address(stake), address(graph), address(feePolicy));
        ProtocolViews views = new ProtocolViews(address(registry), address(stake), address(graph), address(score), address(feePolicy));

        authority.setMinter(address(stake), true);
        authority.setBurner(address(stake), true);

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vm.stopBroadcast();

        _write(string.concat("deployments/", env, ".json"), env, authority, timelock, feePolicy, token, registry, graph, stake, score, views);
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    function _write(
        string memory path,
        string memory env,
        Authority authority,
        TimelockController timelock,
        PostingFeePolicy feePolicy,
        VSPToken token,
        PostRegistry registry,
        LinkGraph graph,
        StakeEngine stake,
        ScoreEngine score,
        ProtocolViews views
    ) internal {
        string memory json;
        json = json.serialize("env", env);
        json = json.serialize("Authority", address(authority));
        json = json.serialize("Timelock", address(timelock));
        json = json.serialize("PostingFeePolicy", address(feePolicy));
        json = json.serialize("VSPToken", address(token));
        json = json.serialize("PostRegistry", address(registry));
        json = json.serialize("LinkGraph", address(graph));
        json = json.serialize("StakeEngine", address(stake));
        json = json.serialize("ScoreEngine", address(score));
        json = json.serialize("ProtocolViews", address(views));
        vm.writeJson(json, path);
    }
}
