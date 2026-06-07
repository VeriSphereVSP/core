#!/bin/bash
# POST-LAUNCH ROLE LOCKDOWN — run after all bounty minting is done.
# Revokes deployer's direct mint/burn. Irreversible without governance.
set -e
# patch_retire_core_env: deploy/admin keys come from SOPS via the resolver now,
# not a plaintext ~/verisphere/.env (that file was removed in Bundle 10 B3). Run
# `vsp-secrets-load` (or source vsp-env-resolve.sh output) before this script.
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY not set — run 'vsp-secrets-load' first}"
RPC_URL="${RPC_URL:-https://api.avax-test.network/ext/bc/C/rpc}"
ADDRESSES_FILE="broadcast/Deploy.s.sol/43113/addresses.json"
[ -f "$ADDRESSES_FILE" ] || { echo "No deployment found"; exit 1; }
AUTHORITY=$(jq -r '.Authority' "$ADDRESSES_FILE")
DEPLOYER=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")
echo "Authority: $AUTHORITY"; echo "Deployer:  $DEPLOYER"
IS_MINTER=$(cast call "$AUTHORITY" "isMinter(address)(bool)" "$DEPLOYER" --rpc-url "$RPC_URL")
IS_BURNER=$(cast call "$AUTHORITY" "isBurner(address)(bool)" "$DEPLOYER" --rpc-url "$RPC_URL")
echo "isMinter: $IS_MINTER  isBurner: $IS_BURNER"
[ "$IS_MINTER" = "false" ] && [ "$IS_BURNER" = "false" ] && { echo "Already locked."; exit 0; }
echo ""; echo "WARNING: Irreversible without governance proposal."
read -p "Revoke deployer mint/burn? [y/N] " confirm
[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Aborted."; exit 0; }
cast send "$AUTHORITY" "setMinter(address,bool)" "$DEPLOYER" false \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC_URL" --gas-price 25000000000
cast send "$AUTHORITY" "setBurner(address,bool)" "$DEPLOYER" false \
    --private-key "$DEPLOYER_PRIVATE_KEY" --rpc-url "$RPC_URL" --gas-price 25000000000
echo "✓ Deployer roles revoked."
