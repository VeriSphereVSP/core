# VeriSphere Core

A highly concise and GitHub‑safe README for the core protocol.

## Overview

VeriSphere is a truth‑staking protocol deployed on Avalanche. The `core/` repository contains the **on‑chain foundation** of the system, including the VSP token and its role‑based authority layer. Higher‑level protocol mechanics—posts, staking, link graph, governance interpretation—are implemented in the application‑layer repositories (`docs`, `backend`, `frontend`).

This README provides both a **high‑level explanation** of VeriSphere and a **technical reference** for developers working directly with this repo.

---

## 1. What VeriSphere Is (High‑Level)

VeriSphere is a **truth‑staking market**.

- Anyone can publish a claim.
- Anyone can stake **for** (support) or **against** (challenge) any claim.
- Being *right* earns VSP (minted).
- Being *wrong* loses VSP (burned).
- Claims are linked together as evidence using a directed support/challenge graph.

There are no moderators, votes, reputation systems, or popularity metrics.  
Truth emerges economically: **correct ideas accrue capital; incorrect ideas leak it.**

---

## 2. What’s Inside This Repo

This repository contains the **core EVM‑level primitives** needed by the protocol:

- **`VSPToken.sol`** — ERC‑20 token with governance‑controlled minting & burning.  
  *Idle decay has been removed from MVP.*
- **`Authority.sol`** — Lightweight role system controlling who may mint or burn.
- **Deployment scripts** (Foundry) for Fuji & Avalanche C‑Chain.
- **Comprehensive Foundry tests** for token + authority behavior.

The rest of the protocol lives elsewhere:

| Subsystem | Repo |
|----------|-------|
| Posting, staking, VS logic | `verisphere/backend` |
| LinkGraph + evidence propagation | `verisphere/backend` |
| UI (web client) | `verisphere/frontend` |
| Whitepaper + architecture spec | `verisphere/docs` |

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

## 4. VSP Token (Technical Overview)

`VSPToken` is a minimal, governance‑controlled ERC‑20.

### 4.1 Features

- Standard ERC‑20 compatibility
- Minting restricted to authorized minters
- Burning restricted to authorized burners
- `Authority` contract manages roles

No other token logic (no idle decay, no staking mechanics) is included in MVP.

### 4.2 Roles

`Authority.sol` defines:

- **Owner**
- **Minter**
- **Burner**

Owner has the exclusive ability to:

- Set new owner  
- Add/remove minters  
- Add/remove burners  

VSP token actions are gated:

```
mint → onlyMinter
burn / burnFrom → onlyBurner
```

This allows the staking engine, treasury, or governance hub (in other repos) to mint or burn VSP as needed.

---

## 5. Development: Build & Test

### 5.1 Install Foundry

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 5.2 Install Dependencies

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-git
```

### 5.3 Build

```bash
forge build
```

### 5.4 Run Tests

```bash
forge test -vv
```

The existing suite covers:

- Minting as allowed / forbidden
- Burning as allowed / forbidden
- `burnFrom` + allowance behavior
- Owner‑controlled role assignment
- Unauthorized role modification reverts

---

## 6. Deployment to Avalanche

### 6.1 Environment Variables

```bash
export FUJI_RPC="https://api.avax-test.network/ext/bc/C/rpc"
export AVAX_RPC="https://api.avax.network/ext/bc/C/rpc"
export PRIVATE_KEY="0xYOUR_KEY"
```

Use a **test key** on Fuji and a **hardware wallet** or multisig for mainnet.

### 6.2 Fuji Deployment

```bash
forge script script/DeployVSP.s.sol:DeployVSP   --rpc-url "$FUJI_RPC"   --private-key "$PRIVATE_KEY"   --broadcast -vvvv
```

### 6.3 Mainnet Deployment

```bash
forge script script/DeployVSP.s.sol:DeployVSP   --rpc-url "$AVAX_RPC"   --private-key "$PRIVATE_KEY"   --broadcast -vvvv
```

---

## 7. Integration with the Full Protocol

Although this repo only provides the token layer, it integrates with:

- **Staking Engine:** Burns or mints VSP as users win or lose truth stakes.
- **Post Registry:** Uses VSP for posting fees.
- **Governance Hub:** Controls minters/burners via the Authority.
- **Treasury:** Holds VSP for rewards and payouts.

All higher‑level logic is handled in the application layer.

---

## 8. License

MIT — see `LICENSE`.

---

## 9. Status (MVP)

- VSP token: ✔ fully implemented  
- Authority system: ✔ implemented  
- Idle decay: ✘ removed for MVP  
- Staking engine: external repo  
- LinkGraph: external repo  
- Governance vault/hub: external repo  

VeriSphere Core is ready for integration with the rest of the system.
