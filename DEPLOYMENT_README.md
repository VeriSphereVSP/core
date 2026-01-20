# VeriSphere Core Deployment Guide

This document describes how to build, test, and deploy the VeriSphere core smart contracts using Foundry.

---

## Repository Structure

Key directories:

- `src` — Core protocol contracts
- `script` — Deployment scripts
- `test` — Foundry tests
- `deployments` — JSON deployment artifacts

The repository uses a single deployment script:

- `script/Deploy.s.sol`

---

## Prerequisites

You must have:

- Foundry installed (__INLINE_CODE__forge__, __INLINE_CODE__cast__)
- A funded EOA for deployment
- RPC access to Avalanche Fuji (testnet) or Mainnet

---

## Environment Variables

Create a file named `.env` in the repository root:

```bash
PRIVATE_KEY=0xYOUR_PRIVATE_KEY
DEPLOY_ENV=testnet
GOVERNANCE_MULTISIG=0xYOUR_GOV_ADDRESS
AVALANCHE_FUJI_RPC=https://api.avax-test.network/ext/bc/C/rpc
```

Notes:

- `PRIVATE_KEY` must control a funded EOA
- For `DEPLOY_ENV=dev`, governance == deployer
- For `DEPLOY_ENV=testnet__/INLINE_CODE__ or __INLINE_CODE__mainnet`, governance is external

---

## Build

Run:

```bash
forge clean
forge build
```

---

## Test

Run all tests:

```bash
forge test -vv
```

All tests must pass before deployment.

---

## Deployment (Testnet)

Deploy to Avalanche Fuji:

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $AVALANCHE_FUJI_RPC \
  --broadcast \
  --verify
```

This deploys:

- Authority
- TimelockController
- PostingFeePolicy (timelock-governed)
- VSPToken
- PostRegistry
- LinkGraph
- StakeEngine
- ScoreEngine
- ProtocolViews

Deployment addresses are written to:

`deployments/testnet.json`

---

## Posting Fee Governance

The posting fee:

- Is denominated in VSP
- Is burned on post creation
- Gates economic activation
- Is read dynamically by ScoreEngine and ProtocolViews

The fee value is stored in:

`PostingFeePolicy`

Changes must be executed through the TimelockController.

---

## Timelock Usage (Overview)

To change the posting fee in production:

1. Encode a call to `PostingFeePolicy.setPostingFeeVSP`
2. Queue it via the TimelockController
3. Wait for the delay
4. Execute the transaction

This ensures transparent, delayed governance changes.

---

## Notes

- There are no legacy DeployDev / DeployTestnet scripts
- All deployments are parameterized by `DEPLOY_ENV`
- The frontend and app consume protocol state via ProtocolViews

---

## License

MIT

