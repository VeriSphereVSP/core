// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/interfaces/IVSPToken.sol";
import "../src/governance/PostingFeePolicy.sol";

// Inline mock for PostingFeePolicy (missing from this test file)
contract MockPostingFeePolicy {
    uint256 public fee;

    constructor(uint256 initialFee) {
        fee = initialFee;
    }

    function postingFeeVSP() external view returns (uint256) {
        return fee;
    }
}

// Inline mock VSP (minimal, already used in other tests)
contract MockVSP is IVSPToken {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function burn(uint256 amount) external {
        balances[msg.sender] -= amount;
    }

    function burnFrom(address from, uint256 amount) external {
        balances[from] -= amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) { return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) { return true; }
    function balanceOf(address account) external view returns (uint256) { return balances[account]; }
    function approve(address spender, uint256 amount) external returns (bool) { return true; }
    function allowance(address owner, address spender) external view returns (uint256) { return allowances[owner][spender]; }
}

contract ScoreEngineTest is Test {
    PostRegistry registry;
    StakeEngine stake;
    LinkGraph graph;
    ScoreEngine score;

    MockVSP vsp;
    MockPostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(50); // 50 VSP fee

        registry = new PostRegistry(address(vsp), address(feePolicy));
        stake = new StakeEngine(address(vsp));
        graph = new LinkGraph(address(this));

        score = new ScoreEngine(
            address(registry),
            address(stake),
            address(graph),
            address(feePolicy)
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // Mint enough for fees + stakes
        vsp.mint(address(this), 1e30);
        vsp.mint(address(registry), 1e30); // For fee burn in createClaim
        vsp.approve(address(registry), type(uint256).max);
        vsp.approve(address(stake), type(uint256).max);
    }

    function test_VS_Zero_BelowFee() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 49); // Below fee
        assertEq(score.baseVSRay(c), 0);
    }

    function test_VS_NonZero_AtFee() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 50); // At/above fee
        assertEq(score.baseVSRay(c), 1e18);
    }
}
