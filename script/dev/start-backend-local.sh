#!/bin/bash
# Avvia il backend in locale con le env var da SSM Parameter Store (SIT)
# Prerequisiti: tunnel SSH attivo (start-tunnel.sh), config server su localhost:8888

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKEND_DIR="$SCRIPT_DIR/../../../auxdromos-backend"
TENANT_UUID="${1:-63cbb3c1-f6dc-4251-a32d-5729a3d56886}"

echo "📦 Caricamento env var da SSM Parameter Store (/auxdromos/sit/global/)..."

# Carica tutte le env var da SSM
eval "$(aws ssm get-parameters-by-path \
  --path "/auxdromos/sit/global/" \
  --with-decryption \
  --query 'Parameters[].{N:Name,V:Value}' \
  --output json \
  --region us-east-1 | python3 -c "
import sys, json
for p in json.load(sys.stdin):
    name = p['N'].split('/')[-1]
    val = p['V'].replace('\"', '\\\\\"')
    print(f'export {name}=\"{val}\"')
")"

echo "✅ Env var caricate (DB_USERNAME=$DB_USERNAME, PAGOPA_HMAC_SECRET=${PAGOPA_HMAC_SECRET:0:5}...)"

# Verifica tunnel
if ! lsof -iTCP:5463 -sTCP:LISTEN -t &>/dev/null; then
  echo "⚠️  Tunnel SSH non attivo su porta 5463. Avvio..."
  "$SCRIPT_DIR/start-tunnel.sh"
fi

echo "🚀 Avvio backend (profilo dev, security disabilitata, tenant $TENANT_UUID)..."
cd "$BACKEND_DIR"

# Le env var hanno precedenza sulle properties del config server
export CONFIG_SERVER_URL=http://localhost:8888
export SPRING_SECURITY_ENABLED=false
export SPRING_DEFAULT_TENANT_UUID="$TENANT_UUID"

mvn spring-boot:run -Dspring-boot.run.profiles=dev
