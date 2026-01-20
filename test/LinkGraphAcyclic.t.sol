// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/interfaces/IVSPToken.sol";
import "../src/governance/PostingFeePolicy.sol";

contract MockVSP is IVSPToken {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) external {}
    function burn(uint256 amount) external {}
    function burnFrom(address from, uint256 amount) external {
        balances[from] -= amount;
    }
    function transfer(address to, uint256 amount) external returns (bool) { return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) { return true; }
    function balanceOf(address account) external view returns (uint256) { return balances[account]; }
    function approve(address spender, uint256 amount) external returns (bool) { return true; }
    function allowance(address owner, address spender) external view returns (uint256) { return allowances[owner][spender]; }
}

contract MockPostingFeePolicy is IPostingFeePolicy {
    uint256 public fee;

    constructor(uint256 f) {
        fee = f;
    }

    function postingFeeVSP() external view returns (uint256) {
        return fee;
    }
}

contract LinkGraphAcyclicTest is Test {
    PostRegistry registry;
    LinkGraph graph;

    function setUp() public {
        MockVSP vsp = new MockVSP();
        MockPostingFeePolicy feePolicy = new MockPostingFeePolicy(100);

        registry = new PostRegistry(address(vsp), address(feePolicy));

        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));
    }

    function test_OutgoingEdges_ReturnTypedStruct() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, false);

        LinkGraph.Edge[] memory edges = graph.getOutgoing(a);
        assertEq(edges.length, 1);

        assertEq(edges[0].toClaimPostId, b);
        assertEq(edges[0].linkPostId, linkPostId);
        assertEq(edges[0].isChallenge, false);
    }

    function test_Acyclic_RevertsOnCycle() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        registry.createLink(a, b, false);
        registry.createLink(b, c, false);

        vm.expectRevert(); // CycleDetected or similar
        registry.createLink(c, a, false);
    }

    function test_Acyclic_AllowsDAG() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");
        uint256 c = registry.createClaim("C");

        registry.createLink(a, b, false);
        registry.createLink(a, c, false);
        registry.createLink(b, c, false);

        LinkGraph.Edge[] memory outA = graph.getOutgoing(a);
        assertEq(outA.length, 2);

        LinkGraph.IncomingEdge[] memory inC = graph.getIncoming(c);
        assertEq(inC.length, 2);
    }
}
