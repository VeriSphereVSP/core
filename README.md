# VeriSphere Core

Avalanche-based core smart contracts for the **VeriSphere** truth-staking protocol.

This repository contains:

- `VSPToken` — ERC‑20 compatible token with governance‑controlled idle decay
- `Authority` — minimal role‑based access control (owner / minter / burner)
- `IdleDecay` — generic inactivity‑decay mixin used by `VSPToken`
- Foundry scripts for deployment to Avalanche Fuji & C‑Chain
- A Forge test suite for `VSPToken`

The rest of the protocol (claims, staking engine, link graph, governance hub, backend, and UI)
lives in sibling repositories (`docs`, `backend`, `frontend`).

---

## 1. Repository Layout

```text
core/
├── src/
│   ├── VSPToken.sol              # VSP ERC20 token with idle decay + Authority
│   ├── authority/
│   │   └── Authority.sol         # owner, minter, burner roles
│   ├── staking/
│   │   └── IdleDecay.sol         # time‑based idle decay helper
│   └── interfaces/
│       └── IVSPToken.sol         # interface for VSP token
│
├── script/
│   └── DeployVSP.s.sol           # Foundry deployment script (Fuji / mainnet)
│
├── test/
│   └── VSPToken.t.sol            # unit tests for VSPToken + Authority + decay
│
├── lib/
│   └── openzeppelin-contracts/   # installed via `forge install`
│
├── foundry.toml                  # Foundry project config
├── LICENSE
└── README.md
```

---

## 2. VSP Token Design

`VSPToken` extends OpenZeppelin’s `ERC20` and composes:

- `Authority` for role‑based control of mint / burn
- `IdleDecay` for per‑account idle‑time decay

### 2.1 Roles (Authority)

`Authority.sol` defines:

- `owner` (EOA or contract)
- `isMinter[address]`
- `isBurner[address]`

Only `owner` can call:

- `setOwner(address newOwner)`
- `setMinter(address who, bool allowed)`
- `setBurner(address who, bool allowed)`

`VSPToken` enforces:

- `mint(...)` — `onlyMinter`
- `burn(...)` / `burnFrom(...)` — `onlyBurner`
- `setIdleDecayRate(...)` — `onlyBurner` (during MVP; later governance)

This allows governance (or a multisig) to control Treasury, staking engines, and any
modules that can mint or burn VSP.

---

### 2.2 Idle Decay (Unstaked Value Burn)

`IdleDecay.sol` tracks `lastActivity[user]` and applies an inactivity‑based burn when VSP
is touched (minted, burned, or decay is explicitly applied).

Conceptually:

- Let:
  - $`balance`$ = user’s current token balance
  - $`rateBps`$ = `idleDecayRateBps` (basis points, 10 000 = 100 %)
  - $`elapsed`$ = `block.timestamp - lastActivity[user]`
  - $`Y`$ = `365 days`

- Then the decayed amount is:

  $`decay = \frac{balance \times rateBps \times elapsed}{Y \times 10{,}000}`$

If $`decay > 0`$, the token calls:

- `_beforeTokenBurn(user, decay)` (hook for future accounting)
- `super._burn(user, decay)`

and updates `lastActivity[user] = block.timestamp`.

> **Important:** In MVP, `IdleDecay` is only attached to VSP itself. The *claims* and
> *staking engine* contracts will implement separate economics (truth‑aligned yield vs
> burn) using VSP balances.

---

### 2.3 Governance‑Controlled Idle Rate

The protocol specifies that the **idle decay rate** should be tied to a fraction of the
US 10‑Year Treasury yield:

- Let $`y`$ be the current US10Y annualized yield (as a fraction, e.g. 0.04 for 4 %).
- Then the MVP policy is:

$` \text{idleDecayRate} \approx \frac{y}{10} `$

which is about **one‑tenth of US10Y per year**. Converted to basis points:

$` \text{idleDecayRateBps} \approx 
\left\lfloor \frac{y \cdot 10000}{10} \right\rfloor `$

Example: if US10Y ≈ 4.0 %, $`y = 0.04`$ → $`idleDecayRateBps ≈ 40`$ (0.4 % / year).

This rate is set **off‑chain by governance** and written on‑chain via `setIdleDecayRate`.
The smart contract **does not hard‑cap** the rate; safety is a governance concern.

---

## 3. Build & Test

### 3.1 Prerequisites

- **Foundry** installed (`forge`, `cast`, `anvil`):

  ```bash
  curl -L https://foundry.paradigm.xyz | bash
  source ~/.bashrc
  foundryup
  ```

- `git` and a recent `solc` (Foundry manages this internally).

### 3.2 Install Dependencies

From the `core/` directory:

```bash
forge install OpenZeppelin/openzeppelin-contracts --no-git
```

This will create `lib/openzeppelin-contracts` and its sub‑dependencies.

### 3.3 Build

```bash
forge build
```

### 3.4 Run Tests

```bash
forge test
```

With verbose traces:

```bash
forge test -vvv
```

The test suite in `test/VSPToken.t.sol` currently covers:

- owner / minter / burner role behavior
- minting by authorized vs unauthorized accounts
- burning and burnFrom flows
- allowance checks and reverts
- idle decay application when:
  - minting after time passes
  - explicit `applyIdleDecay` calls
  - decay rate is zero (no effect)
- lastActivity tracking and update patterns

All tests should pass before deployment.

---

## 4. Deployment (Avalanche)

Deployment uses Foundry scripts (`script/DeployVSP.s.sol`).  
You can target both **Fuji (testnet)** and **Avalanche C‑Chain (mainnet)**.

### 4.1 Environment Variables

Set an RPC URL and deployer key:

```bash
export FUJI_RPC="https://api.avax-test.network/ext/bc/C/rpc"
export AVAX_RPC="https://api.avax.network/ext/bc/C/rpc"
export PRIVATE_KEY="0xYOUR_PRIVATE_KEY"
```

> **Security:** use a test key on Fuji; use hardware / secure key management for mainnet.

### 4.2 Deploy to Fuji (Testnet)

```bash
forge script script/DeployVSP.s.sol:DeployVSP   --rpc-url "$FUJI_RPC"   --private-key "$PRIVATE_KEY"   --broadcast   -vvvv
```

This will:

1. Deploy `Authority`
2. Deploy `VSPToken` with the deployer as initial owner
3. Configure the deployer as minter and burner (for MVP bootstrap)

Copy the resulting addresses into:

- your `docs` repo (whitepaper / architecture)
- your backend config
- your frontend environment

### 4.3 Deploy to Avalanche C‑Chain (Mainnet)

Once audited and ready:

```bash
forge script script/DeployVSP.s.sol:DeployVSP   --rpc-url "$AVAX_RPC"   --private-key "$PRIVATE_KEY"   --broadcast   -vvvv
```

Optionally add `--verify` and configure the `SNOWTRACE_API_KEY` for on‑chain verification
(see `foundry.toml`).

---

## 5. Integration Points

Even though this repo only contains the **token and authority layer**, it is designed
to integrate with the rest of the VeriSphere protocol:

- **Staking Engine (future repo)**
  - Will hold VSP stakes per claim
  - Will call `mint` / `burn` based on truth‑aligned yield and penalties

- **Claim Graph / LinkGraph (future repo)**
  - Will reference VSP balances and stakes
  - VSP may be used as collateral for challenge / support

- **Governance Hub (future repo)**
  - Will control `Authority` roles
  - Will set `idleDecayRateBps`
  - Will manage Treasury and bounty payouts

- **Bounty System (docs + backend)**
  - Uses VSP for contributor rewards
  - Reads token balances and possibly idle‑decayed supply

---

## 6. Development Workflow

Recommended steps when hacking on `core`:

1. **Branch**

   ```bash
   git checkout -b feat/something
   ```

2. **Edit contracts**

   - Add / modify code under `src/`
   - If you extend `VSPToken`, update tests accordingly

3. **Add tests**

   - Put tests in `test/`
   - Prefer behavior‑driven names like `test_RevertWhen_...`

4. **Run:**

   ```bash
   forge fmt
   forge build
   forge test -vv
   ```

5. **Commit & push**

   ```bash
   git commit -am "feat: short description"
   git push origin feat/something
   ```

6. Open a PR in GitHub for review and, eventually, bounty assignment.

---

## 7. License

This repository is licensed under the **MIT License**.  
You are free to use, fork, and extend it, subject to the terms in `LICENSE`.

---

## 8. Status

- Chain target: **Avalanche** (Fuji → C‑Chain)  
- Token: **VSPToken** compiled and fully tested  
- Role system: implemented and covered by tests  
- Idle decay: implemented, governance‑parameterized, tested  

Further protocol components (claims, staking, link graph, governance) are defined in the
VeriSphere whitepaper and technical architecture and implemented in other repositories.
