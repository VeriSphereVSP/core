# VeriSphere Core — Task 3.5: Economic Invariants

This document defines the **economic invariants** and safety properties the VeriSphere core protocol must maintain.
These invariants are intended to be **testable** (unit/fuzz/property tests) and **auditable**.

> **Notation**
> - A post (claim or link) has two stake sides: **Support** and **Challenge**.
> - `A` = total support stake on a post, `D` = total challenge stake on a post, `T = A + D`.
> - “ray” in this repo means **fixed-point scale 1e18** for signed VS values (range `[-1e18, +1e18]`).

---

## I. Token Conservation & Accounting Invariants (StakeEngine)

### I.1 Contract balance matches staked totals
For any post `p`, at any time (after a fully-completed state transition),
the StakeEngine’s VSP balance equals the sum of all lots across all posts, i.e. the value it *custodies*:

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

### I.4 Monotonic `sMax` is safe (but has implications)
`sMax` is **monotonic non-decreasing** (never decreases).

**Safety statement**
- Monotonic `sMax` cannot create free-minting, but it can reduce per-epoch rates for later small posts (because `xRay = T/sMax` shrinks).

---

## II. Score Semantics Invariants (ScoreEngine)

### II.1 BaseVS range is bounded
For any claim `c`:
- `baseVSRay(c) ∈ [-1e18, +1e18]`
- If `T == 0`, `baseVSRay(c) == 0`

---

### II.2 EffectiveVS is bounded and convergent on a DAG
For any claim `c`:
- `effectiveVSRay(c) ∈ [-1e18, +1e18]`

And for a DAG of claim-links (enforced by LinkGraph):
- `effectiveVSRay` is well-defined because all dependencies can be evaluated topologically.

This is the key invariant preventing “multi-hop amplification” from exceeding ±1.

---

### II.3 Symmetry is preserved
Support/challenge symmetry holds:
- If all support and challenge stakes are swapped on all posts (claims and links), then:
  - `baseVSRay` negates
  - `effectiveVSRay` negates

---

### II.4 Link stake meaning is consistent under sign
A link post is itself a staked object. Its VS sign determines whether that link is currently functioning as “supporting” or “challenging”
the dependent claim, consistent with the symmetric rule-set:
- If link VS flips sign, its effect on the dependent claim flips accordingly.

---

## III. Graph Safety Invariants (LinkGraph)

### III.1 Claims graph is acyclic
Claim→claim dependency graph is a DAG (cycle creation reverts).

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

To consider Task 3.5 complete, automated tests should cover:

1. Balance conservation: `balanceOf(stakeEngine) == Σ(A+D)` across stake/withdraw/update sequences.
2. Limited liability: burning never exceeds stake; no underflow.
3. BaseVS and EffectiveVS remain in bounds in fuzz tests (random stake/link graphs, within DAG limits).
4. Multi-hop influences propagate (upstream changes affect downstream) and remain bounded.
5. Cycle detection reverts.
