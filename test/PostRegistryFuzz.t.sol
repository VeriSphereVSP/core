// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import "../src/PostRegistry.sol";
import "../src/LinkGraph.sol";
import "../src/interfaces/IVSPToken.sol";
import "../src/interfaces/IPostingFeePolicy.sol";

import "./mocks/MockVSP.sol";
import "./mocks/MockPostingFeePolicy.sol";

/// @title PostRegistry Fuzz Tests
/// @notice Property-based tests for text normalization, deduplication,
///         and link creation invariants.
contract PostRegistryFuzzTest is Test {
    PostRegistry registry;
    LinkGraph graph;
    MockVSP vsp;

    function setUp() public {
        vsp = new MockVSP();
        MockPostingFeePolicy feePolicy = new MockPostingFeePolicy(0); // zero fee for easy testing

        registry = PostRegistry(
            address(
                new ERC1967Proxy(
                    address(new PostRegistry(address(0))),
                    abi.encodeCall(
                        PostRegistry.initialize,
                        (address(this), address(vsp), address(feePolicy))
                    )
                )
            )
        );

        graph = LinkGraph(
            address(
                new ERC1967Proxy(
                    address(new LinkGraph(address(0))),
                    abi.encodeCall(LinkGraph.initialize, (address(this)))
                )
            )
        );

        graph.setRegistry(address(registry));
        registry.setLinkGraph(address(graph));

        vsp.mint(address(this), 1e36);
        vsp.approve(address(registry), type(uint256).max);
    }

    // ────────────────────────────────────────────────────────────
    // Normalization: case insensitivity
    // ────────────────────────────────────────────────────────────

    /// @notice "Hello World" and "hello world" must be detected as duplicates.
    function testFuzz_CaseInsensitiveDedupe(uint8 seed) public {
        // Create a base string and a case-varied version
        string memory base = "the quick brown fox jumps";
        uint256 id1 = registry.createClaim(base);

        // Try uppercase version — should revert as duplicate
        string memory upper = "THE QUICK BROWN FOX JUMPS";
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim(upper);

        // Mixed case
        string memory mixed = "The Quick Brown Fox Jumps";
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim(mixed);
    }

    // ────────────────────────────────────────────────────────────
    // Normalization: whitespace collapsing
    // ────────────────────────────────────────────────────────────

    /// @notice Multiple spaces, tabs, newlines should normalize to single space.
    function test_WhitespaceCollapsing() public {
        uint256 id1 = registry.createClaim("hello world");

        // Double space
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim("hello  world");

        // Tab
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim("hello\tworld");

        // Newline
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim("hello\nworld");

        // Leading/trailing whitespace
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim("  hello world  ");

        // Multiple mixed whitespace
        vm.expectRevert(abi.encodeWithSelector(PostRegistry.DuplicateClaim.selector, id1));
        registry.createClaim(" \t hello \n\r world \t ");
    }

    // ────────────────────────────────────────────────────────────
    // Normalization: distinct claims stay distinct
    // ────────────────────────────────────────────────────────────

    /// @notice Claims that differ in non-whitespace, non-case characters
    ///         must NOT be treated as duplicates.
    function testFuzz_DistinctClaimsAreDistinct(
        uint8 suffixA,
        uint8 suffixB
    ) public {
        vm.assume(suffixA != suffixB);
        // Ensure printable ASCII range
        uint8 a = uint8(bound(uint256(suffixA), 0x30, 0x7A));
        uint8 b = uint8(bound(uint256(suffixB), 0x30, 0x7A));

        // Avoid case-equivalent pairs (e.g., 'A' and 'a')
        if (a >= 0x41 && a <= 0x5A) a += 32; // lowercase
        if (b >= 0x41 && b <= 0x5A) b += 32;
        vm.assume(a != b);

        string memory textA = string(abi.encodePacked("claim ", bytes1(a)));
        string memory textB = string(abi.encodePacked("claim ", bytes1(b)));

        uint256 idA = registry.createClaim(textA);
        uint256 idB = registry.createClaim(textB);

        assertTrue(idA != idB, "distinct claims got same ID");
    }

    // ────────────────────────────────────────────────────────────
    // Post IDs are sequential starting from 1
    // ────────────────────────────────────────────────────────────

    function testFuzz_PostIdsAreSequential(uint8 count) public {
        uint256 n = bound(uint256(count), 1, 50);

        uint256 prevId = 0;
        for (uint256 i = 0; i < n; i++) {
            string memory text = string(
                abi.encodePacked("sequential claim ", vm.toString(i))
            );
            uint256 id = registry.createClaim(text);
            assertEq(id, prevId + 1, "IDs not sequential");
            prevId = id;
        }
    }

    // ────────────────────────────────────────────────────────────
    // findClaim returns correct ID or sentinel
    // ────────────────────────────────────────────────────────────

    function testFuzz_FindClaimRoundTrip(uint8 seed) public {
        string memory text = string(
            abi.encodePacked("findme ", vm.toString(uint256(seed)))
        );

        // Before creation: not found
        uint256 notFound = registry.findClaim(text);
        assertEq(notFound, type(uint256).max, "should not find before creation");

        // Create
        uint256 id = registry.createClaim(text);

        // After creation: found with correct ID
        uint256 found = registry.findClaim(text);
        assertEq(found, id, "findClaim returned wrong ID");

        // Case-varied lookup should also find it
        string memory upper = string(
            abi.encodePacked("FINDME ", vm.toString(uint256(seed)))
        );
        uint256 foundUpper = registry.findClaim(upper);
        assertEq(foundUpper, id, "case-insensitive findClaim failed");
    }

    // ────────────────────────────────────────────────────────────
    // Claim length limit
    // ────────────────────────────────────────────────────────────

    function testFuzz_ClaimLengthLimit(uint16 extraLen) public {
        uint256 maxLen = registry.MAX_CLAIM_LENGTH();
        uint256 extra = bound(uint256(extraLen), 1, 500);

        // Build a string that's exactly maxLen + extra bytes
        bytes memory longBytes = new bytes(maxLen + extra);
        for (uint256 i = 0; i < longBytes.length; i++) {
            longBytes[i] = 0x61; // 'a'
        }
        string memory longText = string(longBytes);

        vm.expectRevert(
            abi.encodeWithSelector(
                PostRegistry.ClaimTooLong.selector,
                maxLen + extra,
                maxLen
            )
        );
        registry.createClaim(longText);
    }

    /// @notice Claims at exactly MAX_CLAIM_LENGTH should succeed.
    function test_ClaimAtMaxLength() public {
        uint256 maxLen = registry.MAX_CLAIM_LENGTH();
        bytes memory exactBytes = new bytes(maxLen);
        for (uint256 i = 0; i < exactBytes.length; i++) {
            exactBytes[i] = bytes1(uint8(0x61 + (i % 26))); // varied chars
        }
        string memory exactText = string(exactBytes);

        uint256 id = registry.createClaim(exactText);
        assertGt(id, 0, "should succeed at max length");
    }

    // ────────────────────────────────────────────────────────────
    // Empty claims revert
    // ────────────────────────────────────────────────────────────

    function test_EmptyClaimReverts() public {
        vm.expectRevert(PostRegistry.InvalidClaim.selector);
        registry.createClaim("");
    }

    // ────────────────────────────────────────────────────────────
    // Link creation: both ends must exist and be claims
    // ────────────────────────────────────────────────────────────

    function testFuzz_LinkRequiresBothEndsExist(uint256 fakeId) public {
        fakeId = bound(fakeId, 1000, type(uint256).max - 1);

        uint256 real = registry.createClaim("real claim for link test");

        vm.expectRevert(PostRegistry.ToPostDoesNotExist.selector);
        registry.createLink(real, fakeId, false);

        vm.expectRevert(PostRegistry.FromPostDoesNotExist.selector);
        registry.createLink(fakeId, real, false);
    }

    // ────────────────────────────────────────────────────────────
    // Duplicate links revert
    // ────────────────────────────────────────────────────────────

    function test_DuplicateLinkReverts() public {
        uint256 a = registry.createClaim("link dup A");
        uint256 b = registry.createClaim("link dup B");

        registry.createLink(a, b, false); // support link

        // Same direction, same type: should revert
        vm.expectRevert(
            abi.encodeWithSelector(PostRegistry.DuplicateLink.selector, a, b, false)
        );
        registry.createLink(a, b, false);

        // Same direction, different type: should succeed (challenge vs support)
        registry.createLink(a, b, true); // this is a different edge
    }
}
