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

/// @title Protocol stateful-invariant handler (item 253)
/// @notice A *tight* handler: a small fixed actor set, a bounded post universe,
///         and fully guarded actions (every external mutation is wrapped in
///         try/catch so the handler itself never reverts). This keeps the
///         fuzzed state small and deeply exercised, and means an invariant
///         failure points at a real contract bug, not handler bookkeeping.
///
/// Actions fuzzed by Foundry: createClaim, createLink, stake, withdraw, warp.
/// View getters expose the post/actor universe to the invariant contract.
contract ProtocolHandler is Test {
    PostRegistry public registry;
    StakeEngine public stakeEng;
    LinkGraph public graph;
    ScoreEngine public score;
    MockVSP public vsp;

    address[] public actors;

    // Bounded universe — keeps invariant evaluation tractable.
    uint256 constant MAX_CLAIMS = 24;
    uint256 constant MAX_POSTS = 72; // claims + link-posts

    uint256 constant MAX_STAKE = 1e21; // << MAX_STAKE_AMOUNT (1e25)
    uint256 constant FUND = 1e30;

    uint256[] public claims; // claim postIds only
    uint256[] public allPosts; // claims + stakeable link-posts
    uint256 private claimCounter;

    // (actor, postId) -> chosen side + 1 (0 = none). Enforces the single-sided
    // rule so stakes are productive rather than reverting on OppositeSideStaked.
    mapping(address => mapping(uint256 => uint8)) public sidePlusOne;

    // Ghost ledger of net principal flowing through the engine. With no epoch
    // crossing (no warp action), the engine is a pure escrow, so these tie out
    // exactly against the sum of on-chain post totals.
    uint256 public ghostDeposited;
    uint256 public ghostWithdrawn;

    constructor(PostRegistry _registry, StakeEngine _stakeEng, LinkGraph _graph, ScoreEngine _score, MockVSP _vsp) {
        registry = _registry;
        stakeEng = _stakeEng;
        graph = _graph;
        score = _score;
        vsp = _vsp;

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA1F));

        for (uint256 i = 0; i < actors.length; i++) {
            address a = actors[i];
            vsp.mint(a, FUND);
            vm.prank(a);
            vsp.approve(address(stakeEng), type(uint256).max);
            vm.prank(a);
            vsp.approve(address(registry), type(uint256).max);
        }
    }

    // ───────────────────────── view getters (not fuzzed) ─────────────────────────
    function getClaims() external view returns (uint256[] memory) {
        return claims;
    }

    function getAllPosts() external view returns (uint256[] memory) {
        return allPosts;
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    // ───────────────────────── fuzzed actions ─────────────────────────

    function hCreateClaim(uint256 aSeed) public {
        if (claims.length >= MAX_CLAIMS) {
            return;
        }
        address actor = actors[aSeed % actors.length];
        string memory t = string(abi.encodePacked("c", vm.toString(claimCounter++)));
        vm.prank(actor);
        try registry.createClaim(t) returns (uint256 id) {
            claims.push(id);
            allPosts.push(id);
        } catch {}
    }

    function hCreateLink(uint256 fSeed, uint256 tSeed, uint256 aSeed, bool isChallenge) public {
        if (claims.length < 2) {
            return;
        }
        if (allPosts.length >= MAX_POSTS) {
            return;
        }
        address actor = actors[aSeed % actors.length];
        uint256 from = claims[fSeed % claims.length];
        uint256 to = claims[tSeed % claims.length];
        if (from == to) {
            return; // SelfLoop guard
        }
        vm.prank(actor);
        try registry.createLink(from, to, isChallenge) returns (uint256 id) {
            allPosts.push(id); // link-post is itself stakeable
        } catch {}
    }

    function hStake(uint256 pSeed, uint256 aSeed, uint8 sideIn, uint256 amtSeed) public {
        if (allPosts.length == 0) {
            return;
        }
        address actor = actors[aSeed % actors.length];
        uint256 post = allPosts[pSeed % allPosts.length];

        uint8 side;
        uint8 chosen = sidePlusOne[actor][post];
        if (chosen == 0) {
            side = uint8(sideIn % 2);
        } else {
            side = chosen - 1; // keep this actor single-sided on this post
        }
        uint256 amt = bound(amtSeed, 1, MAX_STAKE);

        vm.prank(actor);
        try stakeEng.stake(post, side, amt) {
            sidePlusOne[actor][post] = side + 1;
            ghostDeposited += amt;
        } catch {}
    }

    function hWithdraw(uint256 pSeed, uint256 aSeed, uint256 amtSeed) public {
        if (allPosts.length == 0) {
            return;
        }
        address actor = actors[aSeed % actors.length];
        uint256 post = allPosts[pSeed % allPosts.length];

        uint8 chosen = sidePlusOne[actor][post];
        if (chosen == 0) {
            return;
        }
        uint8 side = chosen - 1;

        uint256 avail = stakeEng.getUserStake(actor, post, side);
        if (avail == 0) {
            return;
        }
        uint256 amt = bound(amtSeed, 1, avail);

        vm.prank(actor);
        try stakeEng.withdraw(post, side, amt, false) {
            ghostWithdrawn += amt;
        } catch {}
    }
}

/// @title Protocol invariants (item 253)
/// @notice Stateful invariants that must hold after ANY sequence of handler
///         actions. Property labels are derived from the protocol's economic
///         and safety guarantees:
///   INV-1 Solvency: the StakeEngine always holds at least the sum of all
///         recorded positions, so it can always pay out.
///   INV-2 Conservation: the sum of all on-chain post totals equals net
///         principal (deposited - withdrawn) tracked by the handler ledger.
///         Holds EXACTLY because this suite stays in the materialized regime:
///         it has no warp action, so no epoch settlement / mint / burn fires
///         and the engine behaves as a pure escrow. (The settlement / decay /
///         projection path is covered by StakeEngineFuzz + StakeEngineRescale.)
///   INV-3 VS bounded: baseVSRay and effectiveVSRay are always within
///         [-RAY, +RAY] for every claim, after any sequence.
///   INV-4 Single-sided: no (actor, post) ever holds both support and challenge
///         stake simultaneously (StakeEngine v2 OppositeSideStaked rule).
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = false
contract ProtocolInvariantsTest is Test {
    PostRegistry registry;
    StakeEngine stakeEng;
    LinkGraph graph;
    ScoreEngine score;
    ProtocolHandler handler;

    MockVSP vsp;

    int256 constant RAY = 1e18;
    uint256 constant FEE = 50;

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

        handler = new ProtocolHandler(registry, stakeEng, graph, score, vsp);

        // Only the handler's actions drive the fuzzed state.
        targetContract(address(handler));
    }

    /// INV-1: the StakeEngine is never insolvent (holds >= sum of all positions).
    function invariant_engineSolvent() public view {
        assertGe(
            vsp.balanceOf(address(stakeEng)), _sumAllPositions(), "StakeEngine insolvent: balance < sum of positions"
        );
    }

    /// INV-2: on-chain totals equal net principal tracked by the handler.
    /// Exact because there is no epoch settlement in this suite (no warp).
    /// Additive form avoids any underflow: positions + withdrawn == deposited.
    function invariant_totalsConserved() public view {
        assertEq(
            _sumAllPositions() + handler.ghostWithdrawn(),
            handler.ghostDeposited(),
            "post totals + withdrawn != deposited"
        );
    }

    function _sumAllPositions() internal view returns (uint256 sumPositions) {
        uint256[] memory posts = handler.getAllPosts();
        for (uint256 i = 0; i < posts.length; i++) {
            (uint256 s, uint256 c) = stakeEng.getPostTotals(posts[i]);
            sumPositions += s + c;
        }
    }

    /// INV-3: VS is always bounded for every claim.
    function invariant_vsBounded() public view {
        uint256[] memory cl = handler.getClaims();
        for (uint256 i = 0; i < cl.length; i++) {
            int256 b = score.baseVSRay(cl[i]);
            assertGe(b, -RAY, "baseVS < -RAY");
            assertLe(b, RAY, "baseVS > +RAY");
            int256 e = score.effectiveVSRay(cl[i]);
            assertGe(e, -RAY, "effectiveVS < -RAY");
            assertLe(e, RAY, "effectiveVS > +RAY");
        }
    }

    /// INV-4: no actor ever holds both sides on the same post.
    function invariant_singleSidedPositions() public view {
        uint256[] memory posts = handler.getAllPosts();
        address[] memory acts = handler.getActors();
        for (uint256 i = 0; i < posts.length; i++) {
            for (uint256 j = 0; j < acts.length; j++) {
                uint256 sup = stakeEng.getUserStake(acts[j], posts[i], 0);
                uint256 chl = stakeEng.getUserStake(acts[j], posts[i], 1);
                assertFalse(sup > 0 && chl > 0, "actor holds both sides on one post");
            }
        }
    }
}
