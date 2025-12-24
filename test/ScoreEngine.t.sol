function test_MultiHopEffectiveVS_LinearChain() public {
    // A -> B -> C
    uint256 A = registry.createClaim("A");
    uint256 B = registry.createClaim("B");
    uint256 C = registry.createClaim("C");

    // Make A strongly positive
    stake.stake(A, stake.SIDE_SUPPORT(), 100);

    // A supports B
    uint256 AB = registry.createLink(A, B, false);
    stake.stake(AB, stake.SIDE_SUPPORT(), 100);

    // B supports C
    uint256 BC = registry.createLink(B, C, false);
    stake.stake(BC, stake.SIDE_SUPPORT(), 100);

    int256 evsA = score.effectiveVSRay(A);
    int256 evsB = score.effectiveVSRay(B);
    int256 evsC = score.effectiveVSRay(C);

    // A should be fully positive
    assertEq(evsA, 1e18);

    // B should inherit positive influence from A
    assertGt(evsB, 0);

    // C should inherit positive influence through B
    assertGt(evsC, 0);

    // Influence should attenuate across hops
    assertGt(evsB, evsC);
}

function test_MultiHopWithChallengePropagation() public {
    // A -> B -> C
    uint256 A = registry.createClaim("A");
    uint256 B = registry.createClaim("B");
    uint256 C = registry.createClaim("C");

    // A is negative (challenge-only)
    stake.stake(A, stake.SIDE_CHALLENGE(), 100);

    // A challenges B
    uint256 AB = registry.createLink(A, B, true);
    stake.stake(AB, stake.SIDE_SUPPORT(), 100);

    // B supports C
    uint256 BC = registry.createLink(B, C, false);
    stake.stake(BC, stake.SIDE_SUPPORT(), 100);

    int256 evsA = score.effectiveVSRay(A);
    int256 evsB = score.effectiveVSRay(B);
    int256 evsC = score.effectiveVSRay(C);

    // A negative
    assertLt(evsA, 0);

    // B should be negative due to challenged support
    assertLt(evsB, 0);

    // C should inherit negative influence through B
    assertLt(evsC, 0);
}

function test_MultiHopMixedInfluence() public {
    // A -> C
    // B -> C
    uint256 A = registry.createClaim("A");
    uint256 B = registry.createClaim("B");
    uint256 C = registry.createClaim("C");

    // A positive
    stake.stake(A, stake.SIDE_SUPPORT(), 100);

    // B negative
    stake.stake(B, stake.SIDE_CHALLENGE(), 100);

    // Links
    uint256 AC = registry.createLink(A, C, false);
    uint256 BC = registry.createLink(B, C, false);

    stake.stake(AC, stake.SIDE_SUPPORT(), 100);
    stake.stake(BC, stake.SIDE_SUPPORT(), 100);

    int256 evsC = score.effectiveVSRay(C);

    // Mixed influence → magnitude reduced
    assertLt(evsC, 1e18);
    assertGt(evsC, -1e18);
}

