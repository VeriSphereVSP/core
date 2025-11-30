# VeriSphere Core (Revised with Updated Staking Model)

## Overview

VeriSphere is a truth-staking protocol deployed on Avalanche. The `core/` repository contains the on-chain foundation of the system, including the VSP token and its role-based authority layer.

This README has been updated to reflect the new global staking model:

- Global rate band (Rmin to Rmax)
- Post Reward Factor P (anti-fracturing)
- Positional reward weighting
- Reward neutrality when VS = 0
- Idle decay removed from MVP

Higher-level protocol mechanics are implemented in the application-layer repositories (`docs`, `backend`, `frontend`).

---

## 1. VeriSphere as a Truth-Staking Market

VeriSphere is a capital-weighted epistemic game:

- Publishing a claim ("Post")
- Staking support (for) or challenge (against)
- Correct stake mints VSP
- Incorrect stake burns VSP
- Claims connected through a directed support/challenge graph

No moderators, votes, or reputation systems. Truth emerges economically.

---

## 2. What's Inside This Repo

- `VSPToken.sol`: ERC-20 token with governance-controlled mint/burn
- `Authority.sol`: Owner/minter/burner role controller
- Foundry deployment scripts
- Foundry test suite

---

## 3. Repository Structure

```
core/
├── src/
│   ├── VSPToken.sol
│   ├── authority/
│   │   └── Authority.sol
│   └── interfaces/
│       └── IVSPToken.sol
│
├── script/
│   └── DeployVSP.s.sol
│
├── test/
│   └── VSPToken.t.sol
│
├── lib/
│   └── openzeppelin-contracts/
│
├── foundry.toml
└── README.md
```
---

## 4. Updated Staking Algorithm Overview

This section summarizes how VSP is minted/burned by upstream systems.

### 4.1 Verity Score (VS)

A = total support stake  
D = total challenge stake

VS = (2 * (A / (A + D)) - 1) * 100  
If A + D = 0 → VS = 0.

### 4.2 Global Rate Band

Governance defines:

Rmin = minimum annual rate  
Rmax = maximum annual rate  
Rrange = Rmax - Rmin

### 4.3 Post Reward Factor P (Anti-Fracturing)

T = total stake on post  
S = total VSP in circulation

P = T / (T + S)

Tiny posts → P ≈ 0  
Large posts → P increases smoothly

### 4.4 VS Sensitivity

v = abs(VS) / 100

### 4.5 Position Weight (Queue-Based)

i = position index (1 = earliest)

w_i = (1 / i) / H_N  
H_N = sum(1/j from j=1 to N)

### 4.6 Alignment Sign

sgn = +1 if stake matches VS direction  
sgn = -1 if opposed  
sgn = 0 if VS = 0

### 4.7 Effective Rate

r_eff = Rmin + Rrange * P * v * w_i

### 4.8 Stake Update Rule

If VS = 0:  
n_next = n

Else:  
delta = n * sgn * r_eff * dt  
n_next = max(0, n + delta)

---

## 5. VSP Token Details

### Roles

- Owner
- Minter
- Burner

Only minters can mint, only burners can burn.

### Fuji Deployment

VSPToken: 0xa8319c13dbA8f4b8d3609910549BF5e9A055c207  
Authority: 0xdcc4AC5b091C0E779CE106c1Ba384aB5C56143c5

---

## 6. Developer Workflow

Build:

    forge build

Test:

    forge test -vv

Deploy (Fuji):

    forge script script/DeployVSP.s.sol:DeployVSP --rpc-url $FUJI_RPC --private-key $PRIVATE_KEY --broadcast -vvvv

Deploy (Mainnet):

    forge script script/DeployVSP.s.sol:DeployVSP --rpc-url $AVAX_RPC --private-key $PRIVATE_KEY --broadcast -vvvv

---

## 7. Integration Notes

Other systems calling mint/burn:

- Staking Engine
- Post Registry
- Treasury / Governance

---

## 8. License

MIT.

---

## 9. Status

Token: complete  
Authority: complete  
Idle decay: removed  
Staking engine: external repo  
LinkGraph: external repo  
Governance hub: external repo
