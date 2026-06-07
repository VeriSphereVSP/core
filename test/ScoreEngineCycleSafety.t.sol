// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

/// @title ScoreEngine Cycle-Safety, Depth-Bound, and Edge-Limit Tests (item 254)
/// @notice Targets the recursion-safety guarantees of effectiveVSRay that the
///         existing ScoreEngineFuzz suite does not cover. Guarantee labels are
///         INFERRED from ScoreEngine.sol (the canonical numbering G-15/16/17 was
///         not found in the repo docs available to the author — correct these
///         comments if the project's numbering differs):
///
///   G-15  Cycle elimination — a link that closes a cycle back to an ancestor
///         under computation contributes exactly zero (ScoreEngine.sol:129-133).
///   G-16  Depth bound — recursion terminates at MAX_DEPTH (=32); contributions
///         from ancestors deeper than MAX_DEPTH are ignored (ScoreEngine.sol:127).
///   G-17  Edge-processing limit — VS computation processes at most
///         `maxIncomingEdges` incoming links, so cost is bounded regardless of
///         fan-in, and the computation is deterministic (ScoreEngine.sol:86-94,
///         182). NOTE: the *structural* 1000-link hard cap (LinkGraph) is already
///         covered by LinkGraphBounds.t.sol and is intentionally not retested here.
///
/// Mirrors the wiring + link-staking pattern of ScoreEngineFuzz.t.sol: a link is
/// itself a staked post (createLink returns a postId, which is then staked to give
/// the edge weight).
contract ScoreEngineCycleSafetyTest is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;

    MockVSP vsp;

    address challenger = address(0xCBA1);

    uint256 constant FEE = 50;
    int256 constant RAY = 1e18;

    // Generous, well-above-fee defaults so every claim/link is active.
    uint256 constant CLAIM_STAKE = FEE * 4;
    uint256 constant LINK_STAKE = FEE * 4;

    function _proxy(address impl, bytes memory data) internal returns (address) {
        return address(new ERC1967Proxy(impl, data));
    }

    function setUp() public {
        vsp = new MockVSP();
        MockProtocolPolicy policy = new MockProtocolPolicy(FEE);

        registry = PostRegistry(
            _proxy(
                address(new PostRegistry(address(0))),
                abi.encodeCall(
                    PostRegistry.initialize,
                    (address(this), address(vsp), address(policy))
                )
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
                abi.encodeCall(
                    StakeEngine.initialize,
                    (address(this), address(vsp), address(policy))
                )
            )
        );

        score = ScoreEngine(
            _proxy(
                address(new ScoreEngine(address(0))),
                abi.encodeCall(
                    ScoreEngine.initialize,
                    (
                        address(this),
                        address(registry),
                        address(stakeEng),
                        address(graph),
                        address(policy),
                        address(policy)
                    )
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp.mint(address(this), 1e36);
        vsp.mint(address(registry), 1e36);
        vsp.approve(address(stakeEng), type(uint256).max);
        vsp.approve(address(registry), type(uint256).max);

        vsp.mint(challenger, 1e36);
        vm.prank(challenger);
        vsp.approve(address(stakeEng), type(uint256).max);
    }

    // ─────────────────────────── helpers ───────────────────────────

    /// @dev Create a claim and stake the support side so it is active.
    function _claim(string memory text, uint256 support) internal returns (uint256 postId) {
        postId = registry.createClaim(text);
        if (support > 0) stakeEng.stake(postId, 0, support);
    }

    /// @dev Create a parent->child link and stake the link-post so the edge has weight.
    function _link(uint256 from, uint256 to, bool isChallenge, uint256 linkStake)
        internal
        returns (uint256 linkId)
    {
        linkId = registry.createLink(from, to, isChallenge);
        if (linkStake > 0) stakeEng.stake(linkId, 0, linkStake);
    }

    function _bounded(int256 vs) internal pure {
        assertGe(vs, -RAY, "VS below -RAY");
        assertLe(vs, RAY, "VS above +RAY");
    }

    // ───────────────────────── G-15: cycles ─────────────────────────

    /// A 2-cycle (A<->B) must not revert and stays bounded.
    function test_TwoCycleDoesNotRevertAndIsBounded() public {
        uint256 a = _claim("A", CLAIM_STAKE);
        uint256 b = _claim("B", CLAIM_STAKE);
        _link(a, b, false, LINK_STAKE);
        _link(b, a, false, LINK_STAKE);
        _bounded(score.effectiveVSRay(a));
        _bounded(score.effectiveVSRay(b));
    }

    /// G-15: adding the cyclic back-edge contributes exactly zero.
    /// effectiveVS(A) is identical with and without the A->B back-edge that
    /// would close the cycle, because the cycle edge is eliminated (returns 0).
    function test_CycleBackEdgeContributesZero() public {
        uint256 a = _claim("A", CLAIM_STAKE);
        uint256 b = _claim("B", CLAIM_STAKE);

        // B -> A only (no cycle yet)
        _link(b, a, false, LINK_STAKE);
        int256 effBefore = score.effectiveVSRay(a);

        // Add A -> B, closing the cycle. This edge must contribute nothing to A.
        _link(a, b, false, LINK_STAKE);
        int256 effAfter = score.effectiveVSRay(a);

        assertEq(effAfter, effBefore, "cyclic back-edge changed VS (should contribute 0)");
    }

    /// G-15, fuzzed over stakes: the cyclic back-edge still contributes zero.
    function testFuzz_CycleBackEdgeContributesZero(uint128 sa, uint128 sb, uint128 sl) public {
        uint256 stakeA = bound(uint256(sa), FEE, 1e24);
        uint256 stakeB = bound(uint256(sb), FEE, 1e24);
        uint256 linkS = bound(uint256(sl), FEE, 1e24);

        uint256 a = _claim("A", stakeA);
        uint256 b = _claim("B", stakeB);

        _link(b, a, false, linkS);
        int256 effBefore = score.effectiveVSRay(a);

        _link(a, b, false, linkS);
        int256 effAfter = score.effectiveVSRay(a);

        assertEq(effAfter, effBefore, "cyclic back-edge changed VS under fuzz");
        _bounded(effAfter);
    }

    // ──────────────────────── G-16: depth bound ─────────────────────

    /// G-16: a chain far deeper than MAX_DEPTH terminates without revert/OOG.
    function test_DeepChainTerminatesWithoutRevert() public {
        uint256 n = 40; // > MAX_DEPTH (32)
        uint256 tip = _claim("tip", CLAIM_STAKE);
        uint256 child = tip;
        for (uint256 i = 1; i < n; i++) {
            uint256 parent = _claim(string(abi.encodePacked("anc", vm.toString(i))), CLAIM_STAKE);
            _link(parent, child, false, LINK_STAKE); // parent -> child
            child = parent;
        }
        int256 vs = score.effectiveVSRay(tip);
        _bounded(vs);
    }

    /// G-16: contributions from ancestors deeper than MAX_DEPTH are ignored.
    /// Build a chain exactly MAX_DEPTH deep, record the tip's VS, then append
    /// strongly-staked ancestors BEYOND depth 32 — the tip's VS must not change.
    function test_ContributionBeyondMaxDepthIgnored() public {
        uint256 maxDepth = 32;
        uint256 tip = _claim("tip", CLAIM_STAKE);

        // chain[k] is the ancestor at depth k; build depths 1..maxDepth
        uint256 child = tip;
        uint256 deepest = tip;
        for (uint256 d = 1; d <= maxDepth; d++) {
            uint256 parent = _claim(string(abi.encodePacked("d", vm.toString(d))), CLAIM_STAKE);
            _link(parent, child, false, LINK_STAKE);
            child = parent;
            deepest = parent;
        }
        int256 vsAtBoundary = score.effectiveVSRay(tip);

        // Append two ancestors at depth 33 and 34 with a heavy OPPOSITE signal
        // (large challenge stake). These sit beyond MAX_DEPTH and must be ignored.
        uint256 ancestor = deepest;
        for (uint256 d = maxDepth + 1; d <= maxDepth + 2; d++) {
            uint256 newAnc = registry.createClaim(string(abi.encodePacked("beyond", vm.toString(d))));
            // heavy challenge so, if it leaked through, it would move the tip down
            vm.prank(challenger);
            stakeEng.stake(newAnc, 1, CLAIM_STAKE * 100);
            _link(newAnc, ancestor, false, LINK_STAKE);
            ancestor = newAnc;
        }
        int256 vsWithBeyond = score.effectiveVSRay(tip);

        assertEq(vsWithBeyond, vsAtBoundary, "ancestor beyond MAX_DEPTH leaked into tip VS");
    }

    // ─────────────────── G-17: edge-processing limit ────────────────

    /// G-17: setting an edge limit of 0 is rejected.
    function test_EdgeLimitZeroReverts() public {
        vm.expectRevert(ScoreEngine.InvalidEdgeLimit.selector);
        score.setEdgeLimits(0, 64);
        vm.expectRevert(ScoreEngine.InvalidEdgeLimit.selector);
        score.setEdgeLimits(64, 0);
    }

    /// G-17: with a low maxIncomingEdges, a high-fan-in claim still computes
    /// without revert, stays bounded, and is deterministic across calls.
    function test_EdgeLimitBoundsFanInDeterministically() public {
        score.setEdgeLimits(2, 64); // process at most 2 incoming edges

        uint256 child = _claim("child", CLAIM_STAKE);
        for (uint256 i = 0; i < 5; i++) {
            uint256 parent = _claim(string(abi.encodePacked("p", vm.toString(i))), CLAIM_STAKE);
            _link(parent, child, false, LINK_STAKE);
        }

        int256 first = score.effectiveVSRay(child);
        int256 second = score.effectiveVSRay(child);
        assertEq(first, second, "VS not deterministic under edge cap");
        _bounded(first);
    }

    /// G-17: the configured edge limits are honoured, and VS stays bounded and
    /// deterministic under both a low and a high cap on the same high-fan-in claim.
    /// (We deliberately do NOT assert capped != full: depending on weights and
    /// RAY-clamping the two can legitimately coincide, so an inequality assertion
    /// would be flaky. The guarantee under test is bounded + deterministic cost.)
    function test_EdgeLimitsHonouredAndStable() public {
        uint256 child = _claim("child", CLAIM_STAKE);
        for (uint256 i = 0; i < 5; i++) {
            uint256 parent = _claim(string(abi.encodePacked("q", vm.toString(i))), CLAIM_STAKE);
            _link(parent, child, false, LINK_STAKE * (i + 1));
        }

        score.setEdgeLimits(2, 64);
        assertEq(score.maxIncomingEdges(), 2, "maxIncomingEdges not set");
        assertEq(score.maxOutgoingLinks(), 64, "maxOutgoingLinks not set");
        int256 capped = score.effectiveVSRay(child);
        _bounded(capped);
        assertEq(capped, score.effectiveVSRay(child), "capped result not deterministic");

        score.setEdgeLimits(64, 64);
        int256 full = score.effectiveVSRay(child);
        _bounded(full);
        assertEq(full, score.effectiveVSRay(child), "full result not deterministic");
    }
}
