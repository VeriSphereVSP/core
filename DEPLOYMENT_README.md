# VeriSphere Core Deployment Guide

## Overview
This document describes how to build, test, and deploy the VeriSphere core protocol
across development, testnet, and mainnet environments.

## Environments
- Dev: local Anvil
- Testnet: Avalanche Fuji
- Mainnet: Avalanche C-Chain

## Build & Test
```
forge clean
forge build
forge test -vv
```

## Deployment Scripts
- DeployDev.s.sol — local testing
- DeployTestnet.s.sol — Fuji testnet
- DeployMainnet.s.sol — mainnet

## Environment Variables
- PRIVATE_KEY
- AUTHORITY_OWNER (testnet)
- GOVERNANCE_MULTISIG (mainnet)

## Deployment Commands
```
forge script script/DeployDev.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/DeployTestnet.s.sol --rpc-url $FUJI_RPC --broadcast
forge script script/DeployMainnet.s.sol --rpc-url $AVAX_RPC --broadcast
```

## Notes
- Every deployment produces new contract addresses
- Authority owner controls mint/burn permissions
- Epoch updates are permissionless and gas-paid by caller

