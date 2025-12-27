# VeriSphere Core — Ops System (Reproducible Setup + Deploy)

This document is the **authoritative, versioned** runbook for setting up a fresh machine to **build, test, and deploy** the `VeriSphereVSP/core` repository.

> **Goal:** A new machine can be provisioned and produce the same results (builds/tests/deploys) with minimal drift.

---

## 1. Supported environment

- OS: **Debian/Ubuntu** (tested on Debian 10+ / Ubuntu 20.04+)
- Shell: bash
- Toolchain: **Foundry** (forge/anvil/cast) pinned
- Git: required
- Node/Python: **not required** for core itself (only for surrounding infra)

---

## 2. Repo layout assumptions

This doc assumes:

- Repo root is `~/verisphere/core`
- Contracts are in `src/`
- Tests are in `test/`
- Deployment scripts are in `script/`:
  - `DeployDev.s.sol`
  - `DeployTestnet.s.sol`
  - `DeployMainnet.s.sol`

---

## 3. Required system packages

```bash
sudo apt update
sudo apt install -y   build-essential   curl   git   jq   ca-certificates
```

Optional but useful:

```bash
sudo apt install -y make unzip
```

---

## 4. Install Foundry (pinned)

Foundry is the **only supported** Solidity toolchain for this repo.

1) Install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
```

2) Load your shell configuration (or open a new terminal):

```bash
source ~/.bashrc
```

3) Pin Foundry to a specific version:

> Replace `FOUNDRY_VERSION_TAG` with the pinned tag you want to standardize on, e.g. `nightly-<date>` or a stable release tag.

```bash
foundryup
# Example pin (if you use nightlies):
# foundryup -v nightly-2024-12-01
```

4) Verify:

```bash
forge --version
cast --version
anvil --version
```

---

## 5. Clone and install dependencies

```bash
mkdir -p ~/verisphere
cd ~/verisphere
git clone https://github.com/VeriSphereVSP/core.git
cd core
```

Install forge libraries (if repo uses submodules / forge install):

```bash
forge install
```

If the repo already vendors libraries under `lib/`, you may not need this step.

---

## 6. Build and test

Clean build:

```bash
cd ~/verisphere/core
forge clean
forge build
```

Run tests:

```bash
forge test -vv
```

If you want gas reports:

```bash
forge test --gas-report
```

---

## 7. Local dev chain (optional)

Run a local chain:

```bash
anvil
```

In a new terminal, you can deploy to the local chain:

```bash
export RPC_URL=http://127.0.0.1:8545
export PRIVATE_KEY=<anvil_private_key>
forge script script/DeployDev.s.sol:DeployDev --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast -vvvv
```

---

## 8. Deployments

### 8.1 Environment variables

You will need:

- `RPC_URL` (Avalanche Fuji / Mainnet / local Anvil)
- `PRIVATE_KEY` (deployer key for that environment)

Example:

```bash
export RPC_URL="https://api.avax-test.network/ext/bc/C/rpc"   # Fuji
export PRIVATE_KEY="0x...."
```

### 8.2 Deploy to Dev

Use when:
- local/anvil, internal devnets, or ephemeral deployments

```bash
forge script script/DeployDev.s.sol:DeployDev   --rpc-url "$RPC_URL"   --private-key "$PRIVATE_KEY"   --broadcast -vvvv
```

### 8.3 Deploy to Testnet (Fuji)

Use when:
- public Fuji deployments

```bash
forge script script/DeployTestnet.s.sol:DeployTestnet   --rpc-url "$RPC_URL"   --private-key "$PRIVATE_KEY"   --broadcast -vvvv
```

### 8.4 Deploy to Mainnet

Use when:
- production deploy with governance/multisig handoffs

```bash
forge script script/DeployMainnet.s.sol:DeployMainnet   --rpc-url "$RPC_URL"   --private-key "$PRIVATE_KEY"   --broadcast -vvvv
```

---

## 9. Operational practices (recommended)

### 9.1 Key management

- Never commit private keys.
- Prefer hardware wallets or secure key stores for mainnet.
- For CI, use repository secrets and ephemeral deploy keys.

### 9.2 Deterministic deploy notes

- Every redeploy produces **new addresses**.
- Your UI/backend should treat the deployment as **versioned**:
  - persist deployed addresses per environment (dev/testnet/mainnet)
  - publish a human-readable deployment manifest

### 9.3 Deployment manifests

Recommended output (copy/paste from forge logs into a checked-in file):

- `deployments/dev.json`
- `deployments/fuji.json`
- `deployments/mainnet.json`

Include:
- chainId
- deployer
- block number
- contract addresses
- git commit hash

---

## 10. Troubleshooting

### 10.1 “Unable to resolve imports”

- Run `forge install`
- Check `foundry.toml` remappings
- Ensure `lib/` exists and is populated

### 10.2 Tests revert unexpectedly

- Re-run with full traces:

```bash
forge test -vvvv
```

### 10.3 RPC issues

- Verify URL is correct and reachable
- Some providers rate-limit; try another endpoint

---

## 11. Where to store this file

Place this document in the **core repo**:

```
core/ops/VERISPHERE_CORE_OPS_SYSTEM.md
```

Commit it so any new machine can reproduce the setup.

---

## 12. Updating this ops system

Any future task that changes:
- repo structure
- build process
- deployment scripts
- required env vars

…must include a corresponding update to this document.

