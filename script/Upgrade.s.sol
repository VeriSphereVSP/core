// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

import "../src/PostRegistry.sol";
import "../src/VSPToken.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";
import "../src/authority/Authority.sol";

/// @title Upgrade
/// @notice Deploys new implementation contracts and upgrades existing proxies.
///         Reads proxy addresses from addresses.json. State is preserved.
///
/// @dev    IMPORTANT: StakeEngine v2 has a breaking storage layout change
///         (lot consolidation, tranche system, snapshot period).
///         Upgrading an existing StakeEngine proxy in-place will corrupt state.
///
///         Options for StakeEngine:
///           1. FRESH_STAKE_ENGINE=true  — Deploy a new proxy + impl, re-wire
///              Authority roles and ScoreEngine/ProtocolViews references.
///              Old proxy is abandoned. Users must re-stake.
///           2. FRESH_STAKE_ENGINE=false — Upgrade in-place. ONLY safe if the
///              existing proxy has no staked funds (e.g., fresh testnet).
///
///         PostRegistry, LinkGraph, ScoreEngine, ProtocolViews are
///         storage-compatible upgrades and can be upgraded in-place safely.
contract Upgrade is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        bool freshStakeEngine = vm.envOr("FRESH_STAKE_ENGINE", false);

        // Read existing addresses
        string memory jsonFile = vm.readFile(
            "broadcast/Deploy.s.sol/43113/addresses.json"
        );
        // Forwarder is deployed separately (see app/contracts/).
        // deploy.sh always passes FORWARDER_ADDRESS; fall back to JSON for manual runs.
        address forwarderAddr = vm.envOr("FORWARDER_ADDRESS", _tryParseForwarder(jsonFile));
        address authorityAddr = vm.parseJsonAddress(jsonFile, ".Authority");
        address vspTokenAddr = vm.parseJsonAddress(jsonFile, ".VSPToken");
        address postRegistryProxy = vm.parseJsonAddress(
            jsonFile,
            ".PostRegistry"
        );
        address linkGraphProxy = vm.parseJsonAddress(jsonFile, ".LinkGraph");
        address stakeEngineProxy = vm.parseJsonAddress(
            jsonFile,
            ".StakeEngine"
        );
        address scoreEngineProxy = vm.parseJsonAddress(
            jsonFile,
            ".ScoreEngine"
        );
        address protocolViewsProxy = vm.parseJsonAddress(
            jsonFile,
            ".ProtocolViews"
        );




        console.log("=== Upgrade Configuration ===");
        console.log("Forwarder:", forwarderAddr);
        console.log("Authority:", authorityAddr);
        console.log("PostRegistry proxy:", postRegistryProxy);
        console.log("LinkGraph proxy:", linkGraphProxy);
        console.log("StakeEngine proxy:", stakeEngineProxy);
        console.log("ScoreEngine proxy:", scoreEngineProxy);
        console.log("ProtocolViews proxy:", protocolViewsProxy);
        { address _tl = _tryParseTimelock(jsonFile);
          if (_tl != address(0)) console.log("TimelockController:", _tl); }
        console.log("FRESH_STAKE_ENGINE:", freshStakeEngine);
        console.log("");

        vm.startBroadcast(pk);

        // ── PostRegistry ────────────────────────────────────────────
        PostRegistry newRegistryImpl = new PostRegistry(forwarderAddr);
        UUPSUpgradeable(postRegistryProxy).upgradeToAndCall(
            address(newRegistryImpl),
            bytes("")
        );
        console.log(
            "PostRegistry upgraded. New impl:",
            address(newRegistryImpl)
        );

        // Grant PostRegistry the burner role (idempotent if already set)
        Authority authority = Authority(authorityAddr);
        if (!authority.isBurner(postRegistryProxy)) {
            authority.setBurner(postRegistryProxy, true);
            console.log("PostRegistry granted burner role");
        }

        // ── VSPToken ─────────────────────────────────────────────
        VSPToken newTokenImpl = new VSPToken(forwarderAddr);
        UUPSUpgradeable(vspTokenAddr).upgradeToAndCall(
            address(newTokenImpl),
            bytes("")
        );
        console.log("VSPToken upgraded. New impl:", address(newTokenImpl));

        // ── LinkGraph ───────────────────────────────────────────────
        LinkGraph newGraphImpl = new LinkGraph(forwarderAddr);
        UUPSUpgradeable(linkGraphProxy).upgradeToAndCall(
            address(newGraphImpl),
            bytes("")
        );
        console.log("LinkGraph upgraded. New impl:", address(newGraphImpl));

        // ── StakeEngine ─────────────────────────────────────────────
        address finalStakeEngineAddr;

        if (freshStakeEngine) {
            console.log("");
            console.log(
                ">>> Deploying FRESH StakeEngine (storage-breaking change) <<<"
            );

            // Deploy new proxy + implementation
            address _rp = address(StakeEngine(stakeEngineProxy).ratePolicy());
            StakeEngine newStakeImpl = new StakeEngine(forwarderAddr);
            ERC1967Proxy newStakeProxy = new ERC1967Proxy(
                address(newStakeImpl),
                abi.encodeCall(
                    StakeEngine.initialize,
                    (deployer, vspTokenAddr, _rp)
                )
            );
            finalStakeEngineAddr = address(newStakeProxy);

            // Grant mint/burn roles to new StakeEngine
            authority.setMinter(finalStakeEngineAddr, true);
            authority.setBurner(finalStakeEngineAddr, true);

            // Revoke roles from old StakeEngine
            authority.setMinter(stakeEngineProxy, false);
            authority.setBurner(stakeEngineProxy, false);

            console.log("New StakeEngine proxy:", finalStakeEngineAddr);
            console.log("New StakeEngine impl:", address(newStakeImpl));
            console.log("Old StakeEngine roles revoked:", stakeEngineProxy);
        } else {
            // In-place upgrade — ONLY safe if no staked funds exist
            StakeEngine newStakeImpl = new StakeEngine(forwarderAddr);
            UUPSUpgradeable(stakeEngineProxy).upgradeToAndCall(
                address(newStakeImpl),
                bytes("")
            );
            finalStakeEngineAddr = stakeEngineProxy;
            console.log(
                "StakeEngine upgraded in-place. New impl:",
                address(newStakeImpl)
            );
            console.log(
                "WARNING: In-place upgrade assumes no existing staked funds."
            );
        }

        // ── ScoreEngine ─────────────────────────────────────────────
        ScoreEngine newScoreImpl = new ScoreEngine(forwarderAddr);
        UUPSUpgradeable(scoreEngineProxy).upgradeToAndCall(
            address(newScoreImpl),
            bytes("")
        );
        console.log("ScoreEngine upgraded. New impl:", address(newScoreImpl));

        // ── ProtocolViews ───────────────────────────────────────────
        ProtocolViews newViewsImpl = new ProtocolViews(forwarderAddr);
        UUPSUpgradeable(protocolViewsProxy).upgradeToAndCall(
            address(newViewsImpl),
            bytes("")
        );
        console.log("ProtocolViews upgraded. New impl:", address(newViewsImpl));

        vm.stopBroadcast();

        // ── Update addresses.json if StakeEngine address changed ────
        if (freshStakeEngine) {
            string memory updatedJson = string.concat(
                '{"Authority":"',
                vm.toString(authorityAddr),

                _tryParseTimelock(jsonFile) != address(0)
                    ? string.concat(
                        '","TimelockController":"',
                        vm.toString(_tryParseTimelock(jsonFile))
                    )
                    : "",
                '","VSPToken":"',
                vm.toString(vspTokenAddr),
                '","PostRegistry":"',
                vm.toString(postRegistryProxy),
                '","LinkGraph":"',
                vm.toString(linkGraphProxy),
                '","StakeEngine":"',
                vm.toString(finalStakeEngineAddr),
                '","ScoreEngine":"',
                vm.toString(scoreEngineProxy),
                '","ProtocolViews":"',
                vm.toString(protocolViewsProxy),
                '"}'
            );
            vm.writeFile(
                "broadcast/Deploy.s.sol/43113/addresses.json",
                updatedJson
            );
            console.log("");
            console.log("addresses.json updated with new StakeEngine address.");
            console.log(
                "Run post-deploy.sh to propagate to protocol/ and app/."
            );
        }

        console.log("");
        console.log("=== Upgrade complete ===");
        if (freshStakeEngine) {
            console.log("StakeEngine: NEW PROXY at", finalStakeEngineAddr);
            console.log("All other proxies: addresses unchanged.");
            console.log("");
            console.log(
                "IMPORTANT: ScoreEngine and ProtocolViews read StakeEngine"
            );
            console.log("via IStakeEngine interface stored at initialization.");
            console.log(
                "If they cache the old address, you may need to re-initialize"
            );
            console.log(
                "or add a governance setter to update the StakeEngine reference."
            );
        } else {
            console.log("All proxies upgraded. Addresses unchanged.");
        }
    }

    /// @dev Try to parse Forwarder from JSON. Returns address(0) if not found.
    function _tryParseTimelock(string memory json) internal view returns (address) {
        try vm.parseJsonAddress(json, ".TimelockController") returns (address t) {
            return t;
        } catch {
            return address(0);
        }
    }

    function _tryParseForwarder(string memory json) internal view returns (address) {
        try vm.parseJsonAddress(json, ".Forwarder") returns (address f) {
            return f;
        } catch {
            return address(0);
        }
    }

}
