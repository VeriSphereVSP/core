# VeriSphere Core — Task 3.5: Economic Invariants

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
- Snapshots (triggered by `_maybeSnapshot` on stake/withdraw, or explicitly via `updatePost`) change totals via growth/decay:
  - winners gain stake → StakeEngine **mints** delta to itself
  - losers lose stake → StakeEngine **burns** delta from itself

**Testability**
- Snapshot totals + `balanceOf(stakeEngine)` before/after stake/withdraw/update.
- Assert exact equality.

---

### I.2 Limited liability (no lot can lose more than its current amount)
For every lot `L`, during a snapshot:
- If the lot is on the losing side, `loss = min(delta, L.amount)`.
- Therefore `L.amount_next >= 0`, and a lot cannot underflow.

---

### I.3 Snapshot cannot mint/burn without stake or pressure
A snapshot is economically neutral (no mint/burn, lot amounts unchanged) when any of the following hold:
- `T == 0` (no stake on the post)
- `sMax == 0` (global reference uninitialized)
- `2A == T` (perfectly balanced support and challenge)
- `epochsElapsed == 0` (no time since last snapshot)

In all such cases the snapshot only updates `lastSnapshotEpoch` and returns.

---

### I.4 sMax dynamics
`sMax` is **not** strictly monotonic. It is tracked via a top-3 list of `(postId, total)` and behaves as follows:

- When the leading post grows past the previous `sMax`, `sMax` is raised to that new value and the decay clock is reset.
- When the leading post shrinks below the previous `sMax`, exponential decay is applied at `0.5%` per epoch (`SMAX_DECAY_RATE_RAY = 995e15`), capped at `SMAX_DECAY_MAX_EPOCHS = 3650` per refresh. The result is then floored at the current leader's total.
- When no leader is tracked, decay applies in pure form (no floor).
- Governance can call `rescanSMax(postIds)` to rebuild the top-3 tracker after upgrades or recovery.

**Safety statement**
- The decay-with-floor design cannot create free minting: rates are always derived from `participation = T / sMax`, and a smaller `sMax` only makes participation (and therefore rates) larger for active posts. The total budget per snapshot is still bounded by `rMax × T`.
- Decay reduces persistent suppression of new posts after a historical peak fades.

---

## II. Score Semantics Invariants (ScoreEngine)

### II.1 BaseVS range is bounded
For any post `p`:
- `baseVSRay(p) ∈ [-1e18, +1e18]`
- If `T == 0`, `baseVSRay(p) == 0`

---

### II.2 EffectiveVS is bounded on any directed graph
For any claim `c`:
- `effectiveVSRay(c) ∈ [-1e18, +1e18]` (clamped explicitly in `_clampRay`)

The `LinkGraph` permits cycles. Boundedness and termination are guaranteed not by graph acyclicity but by the ScoreEngine's computation strategy:

1. **Recursion-stack cycle break.** When computing `effectiveVS` for post `X`, `X` is pushed onto a stack threaded through recursive calls. Before recursing into a parent, the engine scans the stack; if the parent is already present, that parent's contribution is `0` for the current path. `X` cannot influence its own VS through any cycle.
2. **Depth cap.** A hard `MAX_DEPTH = 32` returns `0` from any branch deeper than the cap.
3. **Bounded fan-in.** At most `maxIncomingEdges` incoming links per claim and `maxOutgoingLinks` per parent are processed. Defaults are 64; both are governance-configurable. Edges beyond the limit are silently skipped in insertion order.
4. **Credibility gate.** Parents with `effectiveVS ≤ 0` and links with `baseVS ≤ 0` contribute zero, preventing sign-inversion exploits and cycle oscillation.

This is the key invariant preventing "multi-hop amplification" from exceeding ±1.

---

### II.3 Symmetry is preserved
Support/challenge symmetry holds:
- If all support and challenge stakes are swapped on all posts (claims and links), then:
  - `baseVSRay` negates
  - `effectiveVSRay` negates

---

### II.4 Link stake meaning is consistent under sign
A link post is itself a staked object. Its base VS sign determines whether that link is currently functioning as evidence at all:
- A link with `baseVS > 0` propagates its parent's mass according to its `isChallenge` flag.
- A link with `baseVS ≤ 0` is silenced by the credibility gate and contributes nothing, regardless of `isChallenge`.

The `isChallenge` flag is structural (set at link creation) and cannot flip; community sentiment expressed via stake on the link controls only whether the link is active.

---

### II.5 Off-chain score reproduction must mirror on-chain caps
Any off-chain indexer or analytics layer that computes `effectiveVS` independently must apply the same `maxIncomingEdges` and `maxOutgoingLinks` limits, in the same insertion order as the on-chain `LinkGraph` arrays, to remain consistent with the on-chain value. Otherwise, off-chain values will diverge from the on-chain `effectiveVSRay()` view for high-fan-in claims.

---

## III. Graph Safety Invariants (LinkGraph)

### III.1 Self-loops and exact duplicates are rejected
- `LinkGraph.addEdge` reverts with `SelfLoop` when `fromClaimPostId == toClaimPostId`.
- An edge keyed by `keccak256(from, to, isChallenge)` may exist only once; re-creation reverts with `DuplicateEdge`. Note that this still permits two edges between the same pair of claims if they have different `isChallenge` values (e.g., A supports B and A challenges B coexist as distinct edges and distinct posts).

### III.2 Cycles are permitted at the storage layer
The graph may contain cycles. There is no DFS or ancestor check at write time. All safety related to cyclic propagation is the responsibility of the ScoreEngine (see II.2).

---

## IV. Operational Invariants (Gas / Callers)

### IV.1 `updatePost` is permissionless but must be economically safe
Any address can call `updatePost(postId)`.

**Safety requirements**
- Calling `updatePost` cannot:
  - mint without corresponding lot growth
  - burn other users beyond their lot stake
- The caller only pays gas; they do not gain special economic privilege.
- Repeated calls within the same snapshot period are cheap (early return when no time has elapsed).

### IV.2 `compactLots` is governance-only and economically neutral
- `compactLots(postId, side)` may be called only by governance.
- It removes zero-amount "ghost" lots via swap-and-pop.
- It does not change any non-zero lot amount, side total, or sMax tracking.

### IV.3 `rescanSMax` is governance-only
- `rescanSMax(postIds)` rebuilds the top-3 tracker from a provided set of post IDs.
- It does not mint, burn, or alter any stake amounts; it only changes the `topPosts` array and `sMax`.

---

## V. Minimal Test Coverage Requirements (for signoff)

To consider Task 3.5 complete, automated tests should cover:

1. Balance conservation: `balanceOf(stakeEngine) == Σ(A+D)` across stake/withdraw/snapshot sequences.
2. Limited liability: burning never exceeds stake; no underflow.
3. BaseVS and EffectiveVS remain in bounds in fuzz tests over random stake distributions and arbitrary directed link graphs (including cycles).
4. Multi-hop influences propagate (upstream changes affect downstream) and remain bounded.
5. Cycle handling: a cycle in the link graph does not cause infinite recursion or unbounded gas; the cycled contribution is zero for that path while non-cycled paths compute normally.
6. Fan-in caps: a claim with more than `maxIncomingEdges` incoming links produces the same value as one truncated to the limit.
7. Single-sided position enforcement: staking on the opposite side after an existing position reverts with `OppositeSideStaked`.
8. Lot consolidation: repeated stakes by the same user on the same (post, side) merge into one lot with stake-weighted position averaging; the lot count for that user does not grow.
9. sMax decay-with-floor: after the leader shrinks, sMax decays at the documented rate but never falls below the current leader's total.
