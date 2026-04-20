#!/bin/bash
# POST-LAUNCH ROLE LOCKDOWN — run after all bounty minting is done.
# Revokes deployer's direct mint/burn. Irreversible without governance.
set -e
if [ -f ~/verisphere/.env ]; then set -a; source ~/verisphere/.env; set +a; fi
RPC_URL="${RPC_URL:-https://api.avax-test.network/ext/bc/C/rpc}"
ADDRESSES_FILE="broadcast/Deploy.s.sol/43113/addresses.json"
[ -f "$ADDRESSES_FILE" ] || { echo "No deployment found"; exit 1; }
AUTHORITY=$(jq -r '.Authority' "$ADDRESSES_FILE")
DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Authority: $AUTHORITY"; echo "Deployer:  $DEPLOYER"
IS_MINTER=$(cast call "$AUTHORITY" "isMinter(address)(bool)" "$DEPLOYER" --rpc-url "$RPC_URL")
IS_BURNER=$(cast call "$AUTHORITY" "isBurner(address)(bool)" "$DEPLOYER" --rpc-url "$RPC_URL")
echo "isMinter: $IS_MINTER  isBurner: $IS_BURNER"
[ "$IS_MINTER" = "false" ] && [ "$IS_BURNER" = "false" ] && { echo "Already locked."; exit 0; }
echo ""; echo "WARNING: Irreversible without governance proposal."
read -p "Revoke deployer mint/burn? [y/N] " confirm
[ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Aborted."; exit 0; }
cast send "$AUTHORITY" "setMinter(address,bool)" "$DEPLOYER" false \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --gas-price 25000000000
cast send "$AUTHORITY" "setBurner(address,bool)" "$DEPLOYER" false \
    --private-key "$PRIVATE_KEY" --rpc-url "$RPC_URL" --gas-price 25000000000
echo "✓ Deployer roles revoked."
