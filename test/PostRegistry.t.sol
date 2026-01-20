// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/interfaces/IVSPToken.sol";
import "../src/governance/PostingFeePolicy.sol";  // For mock

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

contract PostRegistryTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    MockVSP vsp;
    MockPostingFeePolicy feePolicy;

    function setUp() public {
        vsp = new MockVSP();
        feePolicy = new MockPostingFeePolicy(100);  // Example fee

        registry = new PostRegistry(address(vsp), address(feePolicy));

        graph = new LinkGraph(address(this));
        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));
    }

    function testCreateClaim() public {
        uint256 id = registry.createClaim("Hello world");

        PostRegistry.Post memory p = registry.getPost(id);
        assertEq(p.creator, address(this));
        assertTrue(p.timestamp > 0);
        assertEq(uint8(p.contentType), uint8(PostRegistry.ContentType.Claim));

        string memory text = registry.getClaim(p.contentId);
        assertEq(text, "Hello world");
    }

    function testCreateSupportLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, false);

        PostRegistry.Post memory lp = registry.getPost(linkPostId);
        assertEq(uint8(lp.contentType), uint8(PostRegistry.ContentType.Link));

        PostRegistry.Link memory l = registry.getLink(lp.contentId);
        assertEq(l.independentPostId, a);
        assertEq(l.dependentPostId, b);
        assertFalse(l.isChallenge);
    }

    function testCreateChallengeLink() public {
        uint256 a = registry.createClaim("A");
        uint256 b = registry.createClaim("B");

        uint256 linkPostId = registry.createLink(a, b, true);

        PostRegistry.Post memory lp = registry.getPost(linkPostId);
        PostRegistry.Link memory l = registry.getLink(lp.contentId);
        assertTrue(l.isChallenge);
    }

    function test_RevertWhen_IndependentClaimDoesNotExist() public {
        uint256 b = registry.createClaim("B");

        vm.expectRevert(PostRegistry.IndependentPostDoesNotExist.selector);
        registry.createLink(9999, b, false);
    }

    function test_RevertWhen_DependentClaimDoesNotExist() public {
        uint256 a = registry.createClaim("A");

        vm.expectRevert(PostRegistry.DependentPostDoesNotExist.selector);
        registry.createLink(a, 9999, false);
    }

    function test_RevertWhen_EmptyClaimText() public {
        vm.expectRevert(PostRegistry.InvalidClaim.selector);
        registry.createClaim("");
    }
}
