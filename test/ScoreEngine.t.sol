// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/VSPToken.sol";
import "../src/authority/Authority.sol";

contract ScoreEngineTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    VSPToken vsp;
    Authority auth;

    address alice = address(0xA11CE);

    function setUp() public {
        vm.startPrank(alice);

        auth = new Authority(alice);
        vsp = new VSPToken(address(auth));

        registry = new PostRegistry();
        graph = new LinkGraph();
        graph.setRegistry(registry);
        registry.setLinkGraph(graph);

        stake = new StakeEngine(address(vsp));
        score = new ScoreEngine(address(registry), address(graph), address(stake));

        auth.setMinter(alice, true);
        auth.setBurner(alice, true);
        auth.setMinter(address(stake), true);
        auth.setBurner(address(stake), true);

        vsp.mint(alice, 1e24);
        vsp.approve(address(stake), type(uint256).max);

        vm.stopPrank();
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    function _claim(string memory txt) internal returns (uint256) {
        vm.prank(alice);
        return registry.createClaim(txt);
    }

    function _link(uint256 from, uint256 to, bool challenge)
        internal
        returns (uint256)
    {
        vm.prank(alice);
        return registry.createLink(from, to, challenge);
    }

    function _stake(uint256 postId, uint8 side, uint256 amt) internal {
        vm.prank(alice);
        stake.stake(postId, side, amt);
    }

    // ------------------------------------------------------------
    // Base sanity
    // ------------------------------------------------------------

    function test_BaseVS_LocalOnly() public {
        uint256 c = _claim("A");
        _stake(c, 0, 100);
        _stake(c, 1, 50);

        int256 vs = score.baseVSRay(c);
        // (100 - 50) / 150 = 1/3
        assertEq(vs, int256(1e18 / 3));
    }

    // ------------------------------------------------------------
    // One-hop symmetry (existing behavior, but explicit)
    // ------------------------------------------------------------

    function test_OneHop_NegativeParentInverts() public {
        uint256 parent = _claim("Parent");
        uint256 child  = _claim("Child");

        // Parent is negative: 20 support, 80 challenge → VS = -0.6
        _stake(parent, 0, 20);
        _stake(parent, 1, 80);

        uint256 link = _link(parent, child, false);

        // Link is "supporting", but parent is negative
        _stake(link, 0, 100);

        int256 vs = score.effectiveVSRay(child);

        // Net contribution should be negative
        assertLt(vs, 0);
    }

    // ------------------------------------------------------------
    // Multi-hop propagation
    // ------------------------------------------------------------

    function test_MultiHop_PositiveChainAmplifies() public {
        //
        // A → B → C
        //
        uint256 A = _claim("A");
        uint256 B = _claim("B");
        uint256 C = _claim("C");

        // A strongly positive
        _stake(A, 0, 100);

        uint256 AB = _link(A, B, false);
        _stake(AB, 0, 50);

        uint256 BC = _link(B, C, false);
        _stake(BC, 0, 50);

        int256 vsA = score.effectiveVSRay(A);
        int256 vsB = score.effectiveVSRay(B);
        int256 vsC = score.effectiveVSRay(C);

        assertGt(vsA, 0);
        assertGt(vsB, 0);
        assertGt(vsC, 0);

        // Influence decays but propagates
        assertGt(vsB, vsC);
    }

    function test_MultiHop_NegativeFlipsTwice() public {
        //
        // A (negative) → B → C
        //
        uint256 A = _claim("A");
        uint256 B = _claim("B");
        uint256 C = _claim("C");

        // A is strongly negative
        _stake(A, 1, 100);

        uint256 AB = _link(A, B, false);
        _stake(AB, 0, 100);

        uint256 BC = _link(B, C, false);
        _stake(BC, 0, 100);

        int256 vsA = score.effectiveVSRay(A);
        int256 vsB = score.effectiveVSRay(B);
        int256 vsC = score.effectiveVSRay(C);

        // A negative
        assertLt(vsA, 0);

        // B negative (inverted once)
        assertLt(vsB, 0);

        // C negative (propagated again, not clamped)
        assertLt(vsC, 0);
    }

    function test_MultiHop_ChallengeLinkInverts() public {
        //
        // A →(challenge)→ B → C
        //
        uint256 A = _claim("A");
        uint256 B = _claim("B");
        uint256 C = _claim("C");

        _stake(A, 0, 100); // positive A

        uint256 AB = _link(A, B, true); // challenge link
        _stake(AB, 0, 100);

        uint256 BC = _link(B, C, false);
        _stake(BC, 0, 100);

        int256 vsB = score.effectiveVSRay(B);
        int256 vsC = score.effectiveVSRay(C);

        // Challenge inverts
        assertLt(vsB, 0);

        // Downstream propagates
        assertLt(vsC, 0);
    }

    function test_NeutralClaimIsInert() public {
        uint256 A = _claim("A");
        uint256 B = _claim("B");

        // A has no stake → VS = 0
        uint256 AB = _link(A, B, false);
        _stake(AB, 0, 100);

        int256 vsB = score.effectiveVSRay(B);
        assertEq(vsB, 0);
    }
}
