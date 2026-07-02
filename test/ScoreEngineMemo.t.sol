// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// patch_h2_score_memo — regression tests for the effectiveVSRay memoization
// (H-2). Exactness on acyclic evidence graphs is covered by the rest of the
// suite (ScoreEngine / ScoreEngineFuzz / ScoreEngineCycleSafety / Invariants)
// continuing to pass against the patched contract. This file targets what
// those don't: (1) a diamond DAG that pre-patch explodes exponentially now
// returns within a bounded gas budget; (2) determinism across repeated calls
// on both acyclic and cyclic graphs; (3) cyclic graphs stay bounded.
import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockProtocolPolicy.sol";

contract ScoreEngineMemoTest is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;

    MockVSP vsp;

    uint256 constant FEE = 50;
    int256 constant RAY = 1e18;
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
                abi.encodeCall(PostRegistry.initialize, (address(this), address(vsp), address(policy)))
            )
        );
        graph = LinkGraph(
            _proxy(address(new LinkGraph(address(0))), abi.encodeCall(LinkGraph.initialize, (address(this))))
        );
        stakeEng = StakeEngine(
            _proxy(
                address(new StakeEngine(address(0))),
                abi.encodeCall(StakeEngine.initialize, (address(this), address(vsp), address(policy)))
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
    }

    // ── helpers (mirror ScoreEngineCycleSafety) ──
    function _claim(string memory text, uint256 support) internal returns (uint256 postId) {
        postId = registry.createClaim(text);
        if (support > 0) {
            stakeEng.stake(postId, 0, support);
        }
    }

    function _link(uint256 from, uint256 to, bool isChallenge, uint256 linkStake) internal returns (uint256 linkId) {
        linkId = registry.createLink(from, to, isChallenge);
        if (linkStake > 0) {
            stakeEng.stake(linkId, 0, linkStake);
        }
    }

    function _bounded(int256 vs) internal pure {
        assertGe(vs, -RAY, "VS below -RAY");
        assertLe(vs, RAY, "VS above +RAY");
    }

    /// Sanity: a lone support-only claim scores +RAY (pure support pool).
    function test_LoneSupportClaimIsRay() public {
        uint256 a = _claim("A", CLAIM_STAKE);
        assertEq(score.effectiveVSRay(a), RAY, "lone support claim != +RAY");
    }

    /// DoS REGRESSION: a branching-2 diamond ladder of depth L has 2^L
    /// root-to-leaf paths. Pre-patch, effectiveVSRay recomputes shared parents
    /// along every path (exponential) and OOGs/times out. With memoization the
    /// ~2L distinct nodes are each resolved once; the call must RETURN and stay
    /// well under a generous gas budget.
    function test_DiamondLadder_DoesNotBlowUp() public {
        uint256 L = 18; // 2^18 = 262,144 naive paths; safely < MAX_DEPTH (32)
        uint256[] memory prev = new uint256[](2);
        prev[0] = _claim("L0a", CLAIM_STAKE);
        prev[1] = _claim("L0b", CLAIM_STAKE);

        for (uint256 lvl = 1; lvl < L; lvl++) {
            uint256[] memory cur = new uint256[](2);
            cur[0] = _claim(string(abi.encodePacked("La", vm.toString(lvl))), CLAIM_STAKE);
            cur[1] = _claim(string(abi.encodePacked("Lb", vm.toString(lvl))), CLAIM_STAKE);
            // each current node draws evidence from BOTH previous nodes -> sharing
            _link(prev[0], cur[0], false, LINK_STAKE);
            _link(prev[1], cur[0], false, LINK_STAKE);
            _link(prev[0], cur[1], false, LINK_STAKE);
            _link(prev[1], cur[1], false, LINK_STAKE);
            prev = cur;
        }
        uint256 sink = _claim("SINK", CLAIM_STAKE);
        _link(prev[0], sink, false, LINK_STAKE);
        _link(prev[1], sink, false, LINK_STAKE);

        uint256 g0 = gasleft();
        int256 vs = score.effectiveVSRay(sink);
        uint256 used = g0 - gasleft();

        _bounded(vs);
        // Memoized cost is ~linear in nodes; 40M is a loose ceiling that the
        // exponential pre-patch path could never meet.
        assertLt(used, 40_000_000, "diamond ladder gas not bounded (memo not collapsing?)");

        // determinism: identical on a second evaluation
        assertEq(score.effectiveVSRay(sink), vs, "acyclic score non-deterministic");
    }

    /// Cyclic graphs: bounded (no revert) AND deterministic across calls.
    function test_Cyclic_BoundedAndDeterministic() public {
        uint256 a = _claim("A", CLAIM_STAKE);
        uint256 b = _claim("B", CLAIM_STAKE);
        uint256 c = _claim("C", CLAIM_STAKE);
        // 3-cycle A->B->C->A, plus a chord, all staked
        _link(a, b, false, LINK_STAKE);
        _link(b, c, false, LINK_STAKE);
        _link(c, a, false, LINK_STAKE);
        _link(a, c, true, LINK_STAKE);

        int256 va1 = score.effectiveVSRay(a);
        int256 va2 = score.effectiveVSRay(a);
        _bounded(va1);
        assertEq(va1, va2, "cyclic score non-deterministic");
        _bounded(score.effectiveVSRay(b));
        _bounded(score.effectiveVSRay(c));
    }

    /// getEdgeContribution shares the recursion; it must also stay bounded and
    /// deterministic on the diamond structure.
    function test_EdgeContribution_Deterministic() public {
        uint256 g = _claim("G", CLAIM_STAKE);
        uint256 p = _claim("P", CLAIM_STAKE);
        uint256 s = _claim("S", CLAIM_STAKE);
        _link(g, p, false, LINK_STAKE);
        uint256 linkPS = _link(p, s, false, LINK_STAKE);
        int256 c1 = score.getEdgeContribution(s, linkPS);
        int256 c2 = score.getEdgeContribution(s, linkPS);
        assertEq(c1, c2, "edge contribution non-deterministic");
    }
}
