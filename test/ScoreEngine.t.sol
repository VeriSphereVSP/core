// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/StakeEngine.sol";
import "../src/ScoreEngine.sol";
import "../src/interfaces/IPostingFeePolicy.sol";

import "./mocks/MockStakeRatePolicy.sol";
import "./mocks/MockClaimActivityPolicy.sol";

// -----------------------------
// Mock Posting Fee Policy
// -----------------------------
contract MockPostingFeePolicy is IPostingFeePolicy {
    uint256 public fee;

    constructor(uint256 initialFee) {
        fee = initialFee;
    }

    function postingFeeVSP() external view override returns (uint256) {
        return fee;
    }
}

// -----------------------------
// Minimal Mock VSP
// -----------------------------
contract MockVSP {
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

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

// -----------------------------
// Tests
// -----------------------------
contract ScoreEngineTest is Test {
    PostRegistry registry;
    StakeEngine stake;
    LinkGraph graph;
    ScoreEngine score;

    MockVSP vsp;
    MockPostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(50);

        MockStakeRatePolicy stakeRatePolicy = new MockStakeRatePolicy();
        MockClaimActivityPolicy activityPolicy = new MockClaimActivityPolicy();

        // ------------------------------------------------------------
        // PostRegistry (proxy)
        // ------------------------------------------------------------
        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry()),
                    abi.encodeCall(
                        PostRegistry.initialize,
                        (
                            address(this),     // governance
                            address(vsp),
                            address(feePolicy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // LinkGraph (proxy)
        // ------------------------------------------------------------
        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph()),
                    abi.encodeCall(
                        LinkGraph.initialize,
                        (address(this)) // governance
                    )
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        // ------------------------------------------------------------
        // StakeEngine (proxy)
        // ------------------------------------------------------------
        stake = StakeEngine(
            address(
                new ERC1967Proxy(
                    address(new StakeEngine()),
                    abi.encodeCall(
                        StakeEngine.initialize,
                        (
                            address(this),           // governance
                            address(vsp),
                            address(stakeRatePolicy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // ScoreEngine (proxy)
        // ------------------------------------------------------------
        score = ScoreEngine(
            address(
                new ERC1967Proxy(
                    address(new ScoreEngine()),
                    abi.encodeCall(
                        ScoreEngine.initialize,
                        (
                            address(this),           // governance
                            address(registry),
                            address(stake),
                            address(graph),
                            address(feePolicy),
                            address(activityPolicy)
                        )
                    )
                )
            )
        );

        // ------------------------------------------------------------
        // Mint enough for fees + stakes
        // ------------------------------------------------------------
        vsp.mint(address(this), 1e30);
        vsp.mint(address(registry), 1e30);
    }

    function test_VS_Zero_BelowFee() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 49);
        assertEq(score.baseVSRay(c), 0);
    }

    function test_VS_NonZero_AtFee() public {
        uint256 c = registry.createClaim("C");

        stake.stake(c, 0, 50);
        assertEq(score.baseVSRay(c), 1e18);
    }
}

