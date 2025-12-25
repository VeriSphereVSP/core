// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/ProtocolViews.sol";
import "../src/interfaces/IVSPToken.sol";

contract PVMockVSP is IVSPToken {
    string private _name = "PVMockVSP";
    string private _symbol = "pVSP";
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
        require(_bal[msg.sender] >= amount, "bal");
        _bal[msg.sender] -= amount;
        _bal[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = _allow[from][msg.sender];
        require(a >= amount, "allow");
        require(_bal[from] >= amount, "bal");
        _allow[from][msg.sender] = a - amount;
        _bal[from] -= amount;
        _bal[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        _totalSupply += amount;
        _bal[to] += amount;
    }

    function burn(uint256 amount) external {
        require(_bal[msg.sender] >= amount, "bal");
        _bal[msg.sender] -= amount;
        _totalSupply -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        require(_bal[from] >= amount, "bal");
        _bal[from] -= amount;
        _totalSupply -= amount;
    }
}

contract ProtocolViewsTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    PVMockVSP vsp;
    StakeEngine stake;
    ScoreEngine score;
    ProtocolViews views_;

    function setUp() public {
        registry = new PostRegistry();

        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp = new PVMockVSP();
        stake = new StakeEngine(address(vsp));
        score = new ScoreEngine(address(registry), address(stake), address(graph));

        views_ = new ProtocolViews(address(registry), address(stake), address(graph), address(score));

        vsp.mint(address(this), 1e30);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_ClaimSummaryAndRawRays() public {
        uint256 a = registry.createClaim("Drug X is safe");

        ProtocolViews.ClaimSummary memory s0 = views_.getClaimSummary(a);
        assertEq(s0.text, "Drug X is safe");
        assertEq(s0.supportStake, 0);
        assertEq(s0.challengeStake, 0);
        assertEq(s0.baseVSRay, 0);
        assertEq(s0.effectiveVSRay, 0);
        assertEq(s0.incomingCount, 0);
        assertEq(s0.outgoingCount, 0);

        stake.stake(a, 0, 100);

        ProtocolViews.ClaimSummary memory s1 = views_.getClaimSummary(a);
        assertEq(s1.supportStake, 100);
        assertEq(s1.challengeStake, 0);
        assertEq(s1.baseVSRay, 1e18);
        assertEq(s1.effectiveVSRay, 1e18);
    }

    function test_OutgoingIncomingEdgesContainMetadata() public {
        uint256 ic = registry.createClaim("Study S showed minimal adverse effects from drug X");
        uint256 dc = registry.createClaim("Drug X is safe");

        uint256 linkPostId = registry.createLink(ic, dc, false);

        LinkGraph.Edge[] memory out = views_.getOutgoingEdges(ic);
        assertEq(out.length, 1);
        assertEq(out[0].toClaimPostId, dc);
        assertEq(out[0].linkPostId, linkPostId);
        assertEq(out[0].isChallenge, false);

        LinkGraph.IncomingEdge[] memory inc = views_.getIncomingEdges(dc);
        assertEq(inc.length, 1);
        assertEq(inc[0].fromClaimPostId, ic);
        assertEq(inc[0].linkPostId, linkPostId);
        assertEq(inc[0].isChallenge, false);

        (uint256 indep, uint256 dep, bool isChal) = views_.getLinkMeta(linkPostId);
        assertEq(indep, ic);
        assertEq(dep, dc);
        assertEq(isChal, false);
    }

    function test_RawRayPassthroughsMatchScoreEngine() public {
        uint256 ic = registry.createClaim("IC");
        uint256 dc = registry.createClaim("DC");

        // Activate DC so effectiveVS isn't gated to 0 in the engine
        stake.stake(dc, 0, 1);

        stake.stake(ic, 0, 100);

        uint256 linkPostId = registry.createLink(ic, dc, false);
        stake.stake(linkPostId, 0, 10);

        int256 bvsViews = views_.getBaseVSRay(dc);
        int256 evsViews = views_.getEffectiveVSRay(dc);

        int256 bvsScore = score.baseVSRay(dc);
        int256 evsScore = score.effectiveVSRay(dc);

        assertEq(bvsViews, bvsScore);
        assertEq(evsViews, evsScore);
    }
}

