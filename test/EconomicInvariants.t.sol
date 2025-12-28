// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/interfaces/IVSPToken.sol";

contract EconomicInvariantsTest is Test {
    TestVSP internal vsp;

    PostRegistry internal registry;
    LinkGraph internal graph;
    StakeEngine internal stake;
    ScoreEngine internal score;

    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);

    function setUp() public {
        vsp = new TestVSP();

        registry = new PostRegistry();

        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        stake = new StakeEngine(address(vsp));
        score = new ScoreEngine(address(registry), address(stake), address(graph));

        vsp.mint(address(this), 1e30);
        vsp.mint(alice, 1e30);
        vsp.mint(bob, 1e30);

        vsp.approve(address(stake), type(uint256).max);
        vm.prank(alice);
        vsp.approve(address(stake), type(uint256).max);
        vm.prank(bob);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_StakeEngineCustodyEqualsTotals_Simple() public {
        uint256 c1 = registry.createClaim("C1");
        uint256 c2 = registry.createClaim("C2");

        stake.stake(c1, 0, 100);
        stake.stake(c1, 1, 40);

        vm.prank(alice);
        stake.stake(c2, 0, 10);

        _assertCustodyEqualsTotals(c1, c2);

        stake.withdraw(c1, 0, 25, true);
        _assertCustodyEqualsTotals(c1, c2);
    }

    function test_StakeEngineCustodyEqualsTotals_AfterUpdate() public {
        uint256 c1 = registry.createClaim("C1");

        stake.stake(c1, 0, 100);
        stake.stake(c1, 1, 20);

        _assertCustodyEqualsTotals(c1);

        vm.warp(block.timestamp + stake.EPOCH_LENGTH() + 1);
        stake.updatePost(c1);

        _assertCustodyEqualsTotals(c1);

        stake.updatePost(c1);
        _assertCustodyEqualsTotals(c1);
    }

    function testFuzz_CustodyEqualsTotals_RandomOps(
        uint96 a0,
        uint96 a1,
        uint96 b0,
        uint96 b1,
        uint8 sideA,
        uint8 sideB,
        bool lifo
    ) public {
        uint256 A0 = bound(uint256(a0), 1, 1e18);
        uint256 A1 = bound(uint256(a1), 1, 1e18);
        uint256 B0 = bound(uint256(b0), 1, 1e18);
        uint256 B1 = bound(uint256(b1), 1, 1e18);

        sideA = uint8(bound(uint256(sideA), 0, 1));
        sideB = uint8(bound(uint256(sideB), 0, 1));

        uint256 c1 = registry.createClaim("C1");
        uint256 c2 = registry.createClaim("C2");

        vm.prank(alice);
        stake.stake(c1, sideA, A0);

        vm.prank(bob);
        stake.stake(c1, sideB, B0);

        stake.stake(c2, 0, A1);
        stake.stake(c2, 1, B1);

        _assertCustodyEqualsTotals(c1, c2);

        vm.warp(block.timestamp + stake.EPOCH_LENGTH() + 5);
        stake.updatePost(c1);

        _assertCustodyEqualsTotals(c1, c2);

        (uint256 sTot, uint256 dTot) = stake.getPostTotals(c1);
        uint256 sideTot = (sideA == 0) ? sTot : dTot;
        uint256 w = bound(uint256(A0 / 2), 0, sideTot);

        if (w > 0) {
            vm.prank(alice);
            try stake.withdraw(c1, sideA, w, lifo) {
                _assertCustodyEqualsTotals(c1, c2);
            } catch {
                _assertCustodyEqualsTotals(c1, c2);
            }
        }
    }

    function test_BaseVS_Bounded() public {
        uint256 c = registry.createClaim("C");
        stake.stake(c, 0, 100);
        stake.stake(c, 1, 50);

        int256 b = score.baseVSRay(c);
        assertTrue(b >= -1e18 && b <= 1e18, "baseVS out of bounds");
    }

    function test_EffectiveVS_Bounded_SimpleLink() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        // Activate DC so effectiveVS(DC) is computed
        stake.stake(dc, 0, 1);

        // IC positive
        stake.stake(ic, 0, 100);

        uint256 link = registry.createLink(ic, dc, false);
        stake.stake(link, 0, 10);

        int256 e = score.effectiveVSRay(dc);
        assertTrue(e >= -1e18 && e <= 1e18, "effectiveVS out of bounds");
    }

	function test_MultiHop_Propagation_Chain3() public {
		// A -> B -> C
		uint256 A = registry.createClaim("A");
		uint256 B = registry.createClaim("B");
		uint256 C = registry.createClaim("C");

		// Activate B and C (otherwise effectiveVSRay returns 0 for gated posts)
		stake.stake(B, 0, 1);
		stake.stake(C, 0, 1);

		uint256 AB = registry.createLink(A, B, false);
		uint256 BC = registry.createLink(B, C, false);

		// Make links heavy so routing is meaningful
		stake.stake(AB, 0, 500);
		stake.stake(BC, 0, 500);

		// Case 1: A strongly positive
		stake.stake(A, 0, 300);
		int256 eC1 = score.effectiveVSRay(C);

		// Case 2: flip A strongly negative
		stake.stake(A, 1, 1200);
		int256 eC2 = score.effectiveVSRay(C);

		// Expect downstream changes
		assertTrue(eC1 != eC2, "downstream did not change");

		// Directional expectation
		assertTrue(eC2 < eC1, "downstream did not move downward");

		// Still bounded
		assertTrue(eC1 >= -1e18 && eC1 <= 1e18, "eC1 out of bounds");
		assertTrue(eC2 >= -1e18 && eC2 <= 1e18, "eC2 out of bounds");
	}


    function test_Cycle_Reverts_IfEnforced() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");

        registry.createLink(A, B, false);

        vm.expectRevert();
        registry.createLink(B, A, false);
    }

    // helpers
    function _assertCustodyEqualsTotals(uint256 p1) internal view {
        uint256 total = _sumTotals(p1);
        assertEq(vsp.balanceOf(address(stake)), total, "custody != totals");
    }

    function _assertCustodyEqualsTotals(uint256 p1, uint256 p2) internal view {
        uint256 total = _sumTotals(p1) + _sumTotals(p2);
        assertEq(vsp.balanceOf(address(stake)), total, "custody != totals");
    }

    function _sumTotals(uint256 postId) internal view returns (uint256) {
        (uint256 s, uint256 d) = stake.getPostTotals(postId);
        return s + d;
    }
}

contract TestVSP is IVSPToken {
    string private _name = "TestVSP";
    string private _symbol = "tVSP";
    uint8 private constant _decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _bal;
    mapping(address => mapping(address => uint256)) private _allow;

    function name() external view returns (string memory) { return _name; }
    function symbol() external view returns (string memory) { return _symbol; }
    function decimals() external pure returns (uint8) { return _decimals; }

    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address owner) external view returns (uint256) { return _bal[owner]; }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allow[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _allow[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= amount, "allowance");
        _allow[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _bal[to] += amount;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(_bal[from] >= amount, "balance");
        _bal[from] -= amount;
        _bal[to] += amount;
    }

    function _burn(address from, uint256 amount) internal {
        require(_bal[from] >= amount, "balance");
        _bal[from] -= amount;
        _totalSupply -= amount;
    }
}


