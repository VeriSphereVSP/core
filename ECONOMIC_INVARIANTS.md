# VeriSphere Core — Economic Invariants

This document defines the **economic invariants** and safety properties the VeriSphere core protocol must maintain.
These invariants are intended to be **testable** (unit/fuzz/property tests) and **auditable**.

> **Notation**
> - A post (claim or link) has two stake sides: **Support** and **Challenge**.
> - `A` = total support stake on a post, `D` = total challenge stake on a post, `T = A + D`.
> - "ray" in this repo means **fixed-point scale 1e18** for signed VS values (range `[-1e18, +1e18]`).

---

## I. Token Conservation & Accounting Invariants (StakeEngine)

### I.1 Contract balance matches staked totals
For any post `p`, at any time (after a fully-completed state transition),
the StakeEngine's VSP balance equals the sum of all lots across all posts, i.e. the value it *custodies*:

- Let `TotalStakedAllPosts = Σ_p (A_p + D_p)`.
- Then **`VSP.balanceOf(StakeEngine) == TotalStakedAllPosts`**.

**Rationale**
- `stake()` transfers VSP from user → StakeEngine and increases lot totals.
- `withdraw()` transfers VSP from StakeEngine → user and decreases lot totals.
- `updatePost()` changes totals via epoch growth/decay:
  - winners gain stake → StakeEngine **mints** delta to itself
  - losers lose stake → StakeEngine **burns** delta from itself

**Testability**
- Snapshot totals + `balanceOf(stakeEngine)` before/after stake/withdraw/update.
- Assert exact equality.

---

### I.2 Limited liability (no lot can lose more than its current amount)
For every lot `L`, during an epoch update:
- If the lot is on the losing side, `loss = min(delta, L.amount)`.
- Therefore `L.amount_next >= 0`, and a lot cannot underflow.

---

### I.3 Epoch settlement cannot mint/burn without stake
If `T == 0` then no minting or burning occurs and lot amounts remain unchanged.

More generally:
- If epoch update is economically neutral (e.g., `VS == 0` or below threshold), no mint/burn occurs.

---

### I.4 sMax tracks the current leader
`sMax` is snapped to the largest active post's total via the top-3
leader tracker on every interaction. There is no slow decay during
normal operation: as soon as the previous leader withdraws below the
second-place total, `sMax` snaps down to the new leader. A
governance-configurable fallback exponential decay (currently 10% per
epoch capped at 30 epochs) only runs when no post has any stake, so
that a stale `sMax` cannot stay frozen forever after a complete
unwind. It is floored at the current leader's total
and raised immediately when a post exceeds it.

**Safety statement**
- Decay prevents historical peaks from permanently suppressing
  participation factors on future posts.
- sMax >= leaderTotal at all times (after update), so participation
  factors remain <= 1.0 in steady state.

---

### I.5 Single-sided positions
A user cannot hold stake on both sides of the same post simultaneously.
`stake()` reverts with `OppositeSideStaked` if the user already has a
non-zero lot on the opposite side.

---

### I.6 Position rescale invariant
After every snapshot, for each side of each post:
- `max(lot.weightedPosition) < sideTotal` for all lots with `amount > 0`.
- This ensures every active lot has `positionWeight > 0` going into the
  next epoch.

---

## II. Score Semantics Invariants (ScoreEngine)

### II.1 BaseVS range is bounded
For any claim `c`:
- `baseVSRay(c) ∈ [-1e18, +1e18]`
- If `T == 0`, `baseVSRay(c) == 0`

---

### II.2 EffectiveVS is bounded and well-defined on cyclic graphs
For any claim `c`:
- `effectiveVSRay(c) ∈ [-1e18, +1e18]`

The effective VS computation is well-defined on any directed graph
(including cycles) because:
- Stack-based cycle detection returns 0 for any post already on the
  computation stack, preventing infinite recursion.
- A hard depth limit of 32 truncates contributions regardless.
- The credibility gate (parent VS ≤ 0 → contribution 0) further
  stabilizes feedback loops.

This is the key invariant preventing "multi-hop amplification" from exceeding ±1.

---

### II.3 Symmetry is preserved
Support/challenge symmetry holds:
- If all support and challenge stakes are swapped on all posts (claims and links), then:
  - `baseVSRay` negates
  - `effectiveVSRay` negates

---

### II.4 Link stake meaning is consistent under sign
A link post is itself a staked object. Its VS sign determines whether that link is currently functioning as "supporting" or "challenging"
the dependent claim, consistent with the symmetric rule-set:
- If link VS flips sign, its effect on the dependent claim flips accordingly.

---

## III. Graph Safety Invariants (LinkGraph)

### III.1 Link graph permits cycles; score computation is cycle-safe
The LinkGraph contract does not enforce acyclicity. Cycles (e.g.,
A challenges B, B challenges A) are permitted at write time.

Cycle safety is enforced at read time by the ScoreEngine:
- Stack-based detection returns 0 for cycled posts.
- Depth limit of 32 prevents unbounded recursion.
- Credibility gate silences posts with VS ≤ 0.

---

## IV. Operational Invariants (Gas / Callers)

### IV.1 `updatePost` is permissionless but must be economically safe
Any address can call `updatePost(postId)`.

**Safety requirements**
- Calling updatePost should not allow:
  - minting without corresponding lot growth
  - burning other users beyond their lot stake
- The caller only pays gas; they do not gain special economic privilege.

---

## V. Minimal Test Coverage Requirements (for signoff)

Automated tests cover:

1. Balance conservation: `balanceOf(stakeEngine) == Σ(A+D)` across stake/withdraw/update sequences.
2. Limited liability: burning never exceeds stake; no underflow.
3. BaseVS and EffectiveVS remain in bounds in fuzz tests (random stake/link graphs).
4. Multi-hop influences propagate (upstream changes affect downstream) and remain bounded.
5. Cycle handling: mutual challenges do not revert; VS remains bounded.
6. Single-sided positions: staking opposite side reverts.
7. Position rescale: after snapshot, all positions < sideTotal.
8. View projections match materialized snapshot values (within rounding tolerance).
