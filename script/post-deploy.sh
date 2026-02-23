#!/bin/bash
# core/script/post-deploy.sh
# Propagates addresses.json to frontend and backend after deployment

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

# Copy to frontend
echo -e "${GREEN}✓ Updating frontend addresses...${NC}"
mkdir -p ../frontend/src/deployments
cp "$ADDRESSES_FILE" "../frontend/src/deployments/${NETWORK}.json"

# Copy to backend
echo -e "${GREEN}✓ Updating backend addresses...${NC}"
mkdir -p ../app/deployments
cp "$ADDRESSES_FILE" "../app/deployments/${NETWORK}.json"

# Rebuild protocol ABIs
echo -e "${GREEN}✓ Rebuilding protocol ABIs...${NC}"
cd ../protocol
npm run generate-abis > /dev/null 2>&1
npm run build > /dev/null 2>&1

echo -e "${GREEN}✅ Post-deployment complete!${NC}"
echo ""
echo "Deployed addresses copied to:"
echo "  - frontend/src/deployments/${NETWORK}.json"
echo "  - app/deployments/${NETWORK}.json"
echo ""
echo "These files should be committed to git."
echo ""
echo "Next steps:"
echo "  1. Rebuild Docker: docker compose build app"
echo "  2. Restart: docker compose up -d app"
