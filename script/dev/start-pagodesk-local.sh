#!/bin/bash
# Avvia pagodesk-service in locale con le env var da SSM Parameter Store (SIT)
# Prerequisiti: tunnel SSH attivo (start-tunnel.sh), config server su localhost:8888
#
# NOTA: il config server deve servire configs/pagodesk/.
# Se la config non è ancora su master di auxdromos-configuration,
# avviare il config server con il repo locale:
#   cd auxdromos-config && SPRING_CLOUD_CONFIG_SERVER_GIT_URI=file:///path/to/auxdromos-configuration mvn spring-boot:run

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAGODESK_DIR="$SCRIPT_DIR/../../../pagodesk-service"
TENANT_UUID="${1:-63cbb3c1-f6dc-4251-a32d-5729a3d56886}"

echo "📦 Caricamento env var da SSM Parameter Store (/auxdromos/sit/global/)..."

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

echo "✅ Env var caricate (DB_USERNAME=$DB_USERNAME)"

# Verifica tunnel
if ! lsof -iTCP:5463 -sTCP:LISTEN -t &>/dev/null; then
  echo "⚠️  Tunnel SSH non attivo su porta 5463. Avvio..."
  "$SCRIPT_DIR/start-tunnel.sh"
fi

echo "🚀 Avvio pagodesk-service (profilo dev, security disabilitata, tenant $TENANT_UUID)..."
cd "$PAGODESK_DIR"

export CONFIG_SERVER_URL=http://localhost:8888
export SPRING_SECURITY_ENABLED=false
export SPRING_DEFAULT_TENANT_UUID="$TENANT_UUID"

mvn spring-boot:run -Dspring-boot.run.profiles=dev
