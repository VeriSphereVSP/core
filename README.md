# VeriSphere Core

## Overview

VeriSphere is a truth‑staking protocol deployed on Avalanche. This `core/` repository contains the on‑chain foundation of the system:

- **VSPToken** (ERC‑20) + **Authority** (role control for mint/burn)
- **PostRegistry** (claims + links as posts)
- **LinkGraph** (directed claim graph; incoming/outgoing edges; **acyclic**)
- **StakeEngine** (staking, epoch updates, mint/burn settlement)
- **ScoreEngine** (pure/read‑only scoring: `baseVS` and `effectiveVS`)
- **ProtocolViews** (read‑only aggregation convenience)

The higher‑level application stack (indexer/backend/frontend) lives in other repos, but **all scoring and settlement rules that must be enforced on‑chain are defined here**.

---

## 1. VeriSphere as a Truth‑Staking Market

VeriSphere is a capital‑weighted epistemic game:

- Users publish **claims**
- Users stake **support** (for) or **challenge** (against)
- Stakes earn **VSP** when aligned with the claim’s settlement score, and are burned when misaligned
- Claims are connected by a directed **support/challenge graph** via link posts

There are no moderators, votes, or reputation scores in the core protocol. Outcomes emerge economically.

---

## 2. Repository Structure (typical)

```
core/
├── script/
│   └── Deploy.s.sol
├── src/
│   ├── LinkGraph.sol
│   ├── PostRegistry.sol
│   ├── PostingFeePolicy.sol
│   ├── ProtocolViews.sol
│   ├── ScoreEngine.sol
│   ├── StakeEngine.sol
│   ├── VSPToken.sol
│   ├── authority/
│   │   └── Authority.sol
│   ├── governance/
│   │   └── PostingFeePolicy.sol
│   ├── interfaces/
│   │   ├── IPostingFeePolicy.sol
│   │   ├── IStakeEngine.sol
│   │   └── IVSPToken.sol
│   └── staking/
│       └── IdleDecay.sol
└── test/
    ├── *.t.sol
    └── mocks/
        ├── MockPostingFe
├── foundry.toml
└── README.md
```

---

## 3. Posts: Claims and Links

### 3.1 Claims

A **claim post** is a statement (e.g., `"Drug X is safe"`). Claims may be *independent* (no incoming edges) or *dependent* (has at least one incoming link from another claim).

### 3.2 Links

A **link post** connects an **independent claim (IC)** to a **dependent claim (DC)**:

- `IC -> DC` with link metadata `isChallenge`:
  - `isChallenge = false`: IC **supports** DC (“IC adds credence to DC”)
  - `isChallenge = true`: IC **challenges** DC (“IC undermines DC”)

A link post itself is stakeable: users can stake **support**/**challenge** on whether the relationship holds.

- Link **support stake** means “yes, this relationship holds”
- Link **challenge stake** means “no, this relationship does not hold”

---

## 4. Verity Score

All scores are conceptually in `[-1, +1]` (implementation uses signed fixed‑point **ray** scaling, typically `1e18`).

Let:

- `S = total support stake` on a post
- `C = total challenge stake` on a post
- `T = S + C`

### 4.1 Base Verity Score (baseVS)

For **any stakeable post** (claim or link):

- If `T = 0`, `baseVS = 0`
- Else:

\[
\text{baseVS} = \frac{S}{S + C} \cdot 2 - 1
\]

This is the simple “support fraction mapped to [-1, +1]”.

---

## 5. Effective Verity Score

### 5.1 Purpose

`effectiveVS(claim)` is the **settlement VS** used for:

- epoch gains/losses on stakes
- minting/burning VSP during epoch updates

`baseVS` is purely local to the claim’s direct stake. `effectiveVS` incorporates **upstream influence** from linked independent claims.

### 5.2 Influence model (Option A: positive-only IC influence)

For a dependent claim **DC**, each incoming link from an independent claim **IC** contributes **additional effective stake** to DC.

#### Key rule (Option A)

If `effectiveVS(IC) <= 0`, that IC contributes **nothing** to dependent claims.

This avoids the “semantic flip” problem where negative‑credibility upstream claims would invert the meaning of link support/challenge.

### 5.3 Link contribution mechanics

For each incoming edge `(IC -> DC)` with link post `L` and flag `isChallenge`:

1) Compute `e = clamp01(effectiveVS(IC))`, where `e` is in `[0, 1]`  
   - Under Option A, if `effectiveVS(IC) <= 0`, skip the link entirely.

2) Read totals on the **link post**:
- `S_L = support stake on L`
- `C_L = challenge stake on L`

3) Discount the link stake by IC credibility:

\[
S_{contrib} = S_L \cdot e \\
C_{contrib} = C_L \cdot e
\]

4) Apply the link direction:

- If `isChallenge = false` (supporting link), add as-is:
  - DC support += `S_contrib`
  - DC challenge += `C_contrib`

- If `isChallenge = true` (challenging link), **swap**:
  - DC support += `C_contrib`
  - DC challenge += `S_contrib`

Intuition: supporting a **challenge link** (“IC undermines DC”) increases challenge pressure on DC; challenging a challenge link increases support pressure on DC.

### 5.4 Effective totals and score

Let DC’s own direct stake totals be `(S_DC, C_DC)`.

Aggregate all incoming contributions:

\[
S_{eff}(DC) = S_{DC} + \sum S_{contrib} \\
C_{eff}(DC) = C_{DC} + \sum C_{contrib}
\]

Then:

\[
effectiveVS(DC) = baseVS(S_{eff}(DC), C_{eff}(DC))
\]

### 5.5 Recursion and acyclicity

Because `effectiveVS(DC)` depends on `effectiveVS(IC)`, and IC may itself be dependent, this is **recursive**.

The graph must be a **DAG** (acyclic). `LinkGraph` enforces acyclicity, so the effectiveVS computation is well-defined: the most independent claims’ scores are computed first and “bubble up”.

---

## 6. Epoch settlement and mint/burn

### 6.1 Where settlement is implemented

Epoch gains/losses and mint/burn settlement are implemented in **StakeEngine**.

At a high level:

- Stakes are recorded per post and side (support/challenge).
- Time is partitioned into **epochs**.
- On `updatePost(postId)` (or equivalent), the contract computes the post’s settlement score for the epoch window, and adjusts user stake positions accordingly.
- Positive PnL results in VSP being **minted**; negative PnL results in VSP being **burned**.

> See `StakeEngine.sol` for the exact epoch math, parameters, and mint/burn calls into `VSPToken` (via the Authority roles).

### 6.2 Reward neutrality at VS = 0

When the settlement score for the relevant post is exactly `0`, the model is reward‑neutral: there is no gain/loss update for that epoch window.

---

## 7. Developer workflow

Build:

```bash
forge build
```

Test:

```bash
forge test -vv
```

---

## 8. License

MIT.

