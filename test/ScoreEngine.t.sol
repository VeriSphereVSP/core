// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";

contract MockVSP {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amt, "allowance");
        allowance[from][msg.sender] = a - amt;
        require(balanceOf[from] >= amt, "bal");
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract ScoreEngineTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    StakeEngine stake;
    ScoreEngine score;
    MockVSP token;

    function setUp() public {
        registry = new PostRegistry();
        graph = new LinkGraph(address(registry));
        registry.setLinkGraph(address(graph));

        token = new MockVSP();
        stake = new StakeEngine(address(token));
        score = new ScoreEngine(address(registry), address(graph), address(stake));

        token.mint(address(this), 1e30);
        token.approve(address(stake), type(uint256).max);
    }

    function test_BaseVS_IsZeroIfNoStake() public {
        uint256 a = registry.createClaim("A");
        assertEq(score.baseVSRay(a), int256(0));
    }

    function test_EffectiveVS_UsesLinkStakeBoundedByLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        // Make A strongly true: stake support 100
        stake.stake(a, 0, 100);

        // Link post L: A supports B
        uint256 linkPostId = registry.createLink(a, b, false);

        // Stake link by 10 support
        stake.stake(linkPostId, 0, 10);

        // B has no direct stake; effective should become strongly positive (~ +1)
        int256 vsEff = score.effectiveVSRay(b);
        assertTrue(vsEff > 9e17); // > 0.9
    }

    function test_EffectiveVS_SupportingWithDubiousClaimHurts() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        // Make A strongly false: challenge 100
        stake.stake(a, 1, 100);

        uint256 linkPostId = registry.createLink(a, b, false);
        stake.stake(linkPostId, 0, 10);

        // Supporting B with a negative-VS claim yields negative contribution
        int256 vsEff = score.effectiveVSRay(b);
        assertTrue(vsEff < -9e17);
    }

    function test_ChallengeLink_FlipsContribution() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        // A strongly true
        stake.stake(a, 0, 100);

        // A challenges B
        uint256 linkPostId = registry.createLink(a, b, true);
        stake.stake(linkPostId, 0, 10);

        int256 vsEff = score.effectiveVSRay(b);
        assertTrue(vsEff < -9e17);
    }
}
