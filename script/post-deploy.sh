#!/bin/bash
# core/script/post-deploy.sh
# Propagates deployment artifacts after a forge deploy.
#
# Dependency graph:
#   core → protocol  (ABIs + addresses)  → frontend consumes via @verisphere/protocol
#   core → app       (addresses only)     → app reads from app/deployments/
#
# app has NO dependency on protocol. Frontend's only cross-repo dep is protocol.

set -e

CHAIN_ID="${1:-43113}"
ADDRESSES_FILE="broadcast/Deploy.s.sol/${CHAIN_ID}/addresses.json"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🔧 Post-deployment processing for chain ${CHAIN_ID}${NC}"

if [ ! -f "$ADDRESSES_FILE" ]; then
  echo "Error: Addresses file not found at $ADDRESSES_FILE"
  exit 1
fi

# Determine network name
if [ "$CHAIN_ID" = "43113" ]; then
  NETWORK="fuji"
elif [ "$CHAIN_ID" = "43114" ]; then
  NETWORK="mainnet"
else
  NETWORK="chain-${CHAIN_ID}"
fi

echo -e "${GREEN}✓ Found addresses for network: ${NETWORK}${NC}"

# ── Protocol: ABIs + addresses ──────────────────────────────────
echo -e "${GREEN}✓ Updating protocol addresses...${NC}"
mkdir -p ../protocol/src/addresses
cp "$ADDRESSES_FILE" "../protocol/src/addresses/${NETWORK}.json"

echo -e "${GREEN}✓ Regenerating protocol ABIs...${NC}"
cd ../protocol
npm run generate-abis > /dev/null 2>&1

echo -e "${GREEN}✓ Building protocol...${NC}"
npm run build > /dev/null 2>&1
cd ../core

# ── App (backend): addresses only ───────────────────────────────
echo -e "${GREEN}✓ Updating backend addresses...${NC}"
mkdir -p ../app/deployments
cp "$ADDRESSES_FILE" "../app/deployments/${NETWORK}.json"

echo -e "${GREEN}✅ Post-deployment complete!${NC}"
echo ""
echo "Artifacts written to:"
echo "  - protocol/src/addresses/${NETWORK}.json  (+ ABIs regenerated & built)"
echo "  - app/deployments/${NETWORK}.json"
