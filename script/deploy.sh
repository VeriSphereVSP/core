#!/bin/bash
# core/script/deploy.sh - Complete deployment pipeline
set -e

RPC_URL="${AVAX_FUJI_RPC:-https://api.avax-test.network/ext/bc/C/rpc}"
CHAIN_ID="43113"

echo "🚀 Starting full deployment pipeline..."

# 1. Build contracts
echo "🔨 Building contracts..."
forge build

# 2. Deploy contracts
echo "📝 Deploying contracts to chain ${CHAIN_ID}..."
forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" \
  --broadcast \
  --verify

# 3. Run post-deployment processing
echo "⚙️  Processing deployment artifacts..."
./script/post-deploy.sh "$CHAIN_ID"

echo ""
echo "✅ Deployment complete!"
echo ""
echo "Deployed addresses:"
cat broadcast/Deploy.s.sol/${CHAIN_ID}/addresses.json
echo ""
echo "Next steps:"
echo "  1. cd ~/verisphere"
echo "  2. docker compose build app"
echo "  3. docker compose up -d app"
echo "  4. ./test-e2e.sh"
