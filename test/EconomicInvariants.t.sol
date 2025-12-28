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

    // ------------------------------------------------------------
    // Multi-hop propagation invariant (corrected)
    // ------------------------------------------------------------
    function test_MultiHop_Propagation_Chain3() public {
        uint256 A = registry.createClaim("A");
        uint256 B = registry.createClaim("B");
        uint256 C = registry.createClaim("C");

        // Activate without saturation
        stake.stake(B, 0, 1);
        stake.stake(B, 1, 1);
        stake.stake(C, 0, 1);
        stake.stake(C, 1, 1);

        uint256 AB = registry.createLink(A, B, false);
        uint256 BC = registry.createLink(B, C, false);

        // Non-saturated but heavy links
        stake.stake(AB, 0, 300);
        stake.stake(AB, 1, 100);

        stake.stake(BC, 0, 300);
        stake.stake(BC, 1, 100);

        stake.stake(A, 0, 300);
        int256 eC1 = score.effectiveVSRay(C);

        stake.stake(A, 1, 1200);
        int256 eC2 = score.effectiveVSRay(C);

        assertTrue(eC1 != eC2);
        assertTrue(eC2 < eC1);
    }

    // ------------------------------------------------------------
    // Existing invariants unchanged
    // ------------------------------------------------------------

    function test_BaseVS_Bounded() public {
        uint256 c = registry.createClaim("C");
        stake.stake(c, 0, 100);
        stake.stake(c, 1, 50);

        int256 b = score.baseVSRay(c);
        assertTrue(b >= -1e18 && b <= 1e18);
    }

    function test_EffectiveVS_Bounded_SimpleLink() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        stake.stake(dc, 0, 1);
        stake.stake(dc, 1, 1);

        stake.stake(ic, 0, 100);

        uint256 link = registry.createLink(ic, dc, false);
        stake.stake(link, 0, 30);
        stake.stake(link, 1, 10);

        int256 e = score.effectiveVSRay(dc);
        assertTrue(e >= -1e18 && e <= 1e18);
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

