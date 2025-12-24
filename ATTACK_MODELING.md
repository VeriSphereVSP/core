# VeriSphere Core — Task 3.5: Attack Modeling & Adversarial Scenarios

This document enumerates realistic attack/griefing scenarios for the on-chain core and describes mitigations.

Goal:

> **Attackers cannot extract unbounded value or destabilize the protocol.**

---

## A. Keeper / Epoch Caller Griefing

### A.1 “No one updates epochs” (liveness failure)
**Attack**
- No one calls `StakeEngine.updatePost(postId)`, so lots never grow/decay and the economic game stalls.

**Mitigations**
- Backend keepers that periodically update popular posts.
- UI-driven updates: frontends call `updatePost` before stake/withdraw.
- Optional on-chain incentive (future): pay the caller a small fee.

---

### A.2 “Excessive updating” (gas grief)
**Attack**
- An attacker repeatedly calls `updatePost` to waste gas.

**Mitigation**
- `updatePost` should be cheap when called multiple times in the same epoch (early return).

---

## B. Stake Splitting / Queue Gaming

### B.1 Split stake into many lots to improve position weight
**Attack**
- Stake 1 token 100 times instead of 100 once.

**Mitigations**
- Ensure weighting is robust to splitting (document if not).
- Future: per-staker aggregation or minimum lot size.

---

## C. Link Spam / Graph Amplification

### C.1 Many incoming links to amplify a claim
**Attack**
- Create hundreds of ICs linked into a DC to amplify effectiveVS.

**Mitigations**
- Normalize contributions so effectiveVS stays in [-1,1].
- Require stake on links so spamming has a cost.

---

### C.2 Deep multi-hop amplification chain
**Attack**
- Build deep chains A→B→C→... to try to “boost” far downstream.

**Mitigations**
- Bounded combination at each hop; compute on DAG order.
- Cap recursion depth or compute iteratively with memoization (implementation detail).

---

## D. Withdrawal / Epoch Timing Attacks

### D.1 Stake right before update, withdraw right after
**Attack**
- Attempt to capture reward with minimal exposure.

**Mitigation**
- Reward is proportional to elapsed time; very short windows yield tiny deltas.

---

## E. Authority / Token Role Misconfiguration

### E.1 StakeEngine cannot mint/burn because roles missing
**Mitigation**
- Deployment scripts must set Authority roles:
  - StakeEngine is minter and burner.

---

## F. Gas / DoS via Large Arrays

### F.1 Many lots make `updatePost` expensive
**Attack**
- Spam tiny lots so update loops over huge arrays.

**Mitigations**
- MVP accepts constraint; keepers focus on important posts.
- Future: aggregation, partial settlement, batching.
