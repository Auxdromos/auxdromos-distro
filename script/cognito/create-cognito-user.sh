#!/usr/bin/env bash
set -euo pipefail

# create-cognito-user.sh
# Obbligatori: username, nome, email, password, tenant_ids, gruppo(USER/ADMIN)
# Region e Pool: richiesti ma con default se invio vuoto.
# Opzionale: --email-verified

DEF_REGION="us-east-1"
DEF_POOL="us-east-1_BiO8rle1y"

REG="$DEF_REGION"
POOL="$DEF_POOL"
USERNAME=""
NAME=""
EMAIL=""
PASS=""
GROUP=""
EMAIL_VERIFIED="false"
TENANT_ARGS=()

ask() {
  local prompt="$1"; local default="${2:-}"; local var
  if [[ -n "$default" ]]; then
    read -rp "$prompt [$default]: " var
    echo "${var:-$default}"
  else
    while true; do
      read -rp "$prompt: " var
      [[ -n "$var" ]] && { echo "$var"; return; }
      echo "Valore obbligatorio."
    done
  fi
}

# parse argomenti rapidi
while (( "$#" )); do
  case "$1" in
    -r) REG="$2"; shift 2 ;;
    -p) POOL="$2"; shift 2 ;;
    -u) USERNAME="$2"; shift 2 ;;
    -n) NAME="$2"; shift 2 ;;
    -e) EMAIL="$2"; shift 2 ;;
    -w) PASS="$2"; shift 2 ;;
    -g) GROUP="$2"; shift 2 ;;
    -t) TENANT_ARGS+=("$2"); shift 2 ;;
    --email-verified) EMAIL_VERIFIED="true"; shift ;;
    -h|--help)
      echo "Uso: $0 [-r regione] [-p pool_id] -u username -n nome -e email -w password -t TENANTS -g USER|ADMIN [--email-verified]"
      exit 0 ;;
    *) echo "Argomento sconosciuto: $1"; exit 1 ;;
  esac
done

# prompt con default per REG/POOL; obbligatori gli altri
REG="${REG:-$DEF_REGION}"
POOL="${POOL:-$DEF_POOL}"
REG="$(ask 'Regione' "$REG")"
POOL="$(ask 'User Pool ID' "$POOL")"

USERNAME=${USERNAME:-$(ask "Username (obbligatorio)")}
NAME=${NAME:-$(ask "Nome (obbligatorio)")}
EMAIL=${EMAIL:-$(ask "Email (obbligatorio)")}
PASS=${PASS:-$(ask "Password (obbligatoria)")}

# TENANTS obbligatorio
if ((${#TENANT_ARGS[@]}==0)); then
  # accetta CSV o JSON
  TENANT_INPUT="$(ask "Tenant IDs (CSV o JSON) (obbligatorio)")"
  TENANT_ARGS+=("$TENANT_INPUT")
fi
# GROUP obbligatorio con validazione USER/ADMIN
if [[ -z "${GROUP:-}" ]]; then
  while true; do
    GROUP="$(ask "Gruppo (USER/ADMIN/ADMIN_DASHBOARD) (obbligatorio)")"
    [[ "$GROUP" == "USER" || "$GROUP" == "ADMIN" || "$GROUP" == "ADMIN_DASHBOARD" ]] && break
    echo "Valido solo USER o ADMIN."
  done
else
  [[ "$GROUP" == "USER" || "$GROUP" == "ADMIN" || "$GROUP" == "ADMIN_DASHBOARD" ]] || { echo "Gruppo deve essere USER o ADMIN"; exit 2; }
fi

normalize_tenants_json() {
  local inputs=("$@"); local flat=()
  for raw in "${inputs[@]}"; do
    [[ -z "$raw" ]] && continue
    if [[ "$raw" =~ ^\[.*\]$ ]]; then
      echo "$raw"; return
    fi
    IFS=',' read -r -a parts <<<"$raw"
    for p in "${parts[@]}"; do
      p="$(echo "$p" | xargs)"; [[ -n "$p" ]] && flat+=("$p")
    done
  done
  if ((${#flat[@]}==0)); then
    echo ""; return
  fi
  local out="["
  for t in "${flat[@]}"; do t="${t//\"/\\\"}"; out="$out\"$t\","; done
  out="${out%,}]"; echo "$out"
}
TENANTS_JSON="$(normalize_tenants_json "${TENANT_ARGS[@]}")"
[[ -z "$TENANTS_JSON" || "$TENANTS_JSON" == "[]" ]] && { echo "Almeno un tenant è richiesto."; exit 3; }

echo "==> Pool: $POOL Regione: $REG Utente: $USERNAME Gruppo: $GROUP Tenants: $TENANTS_JSON"

# 1) crea utente se non esiste
if aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$USERNAME" --region "$REG" >/dev/null 2>&1; then
  echo "Utente già esistente."
else
  echo "Creo utente..."
  ATTRS=(Name=email,Value="$EMAIL" Name=name,Value="$NAME")
  [[ "$EMAIL_VERIFIED" == "true" ]] && ATTRS+=(Name=email_verified,Value=true)
  aws cognito-idp admin-create-user \
    --user-pool-id "$POOL" --region "$REG" \
    --username "$USERNAME" \
    --message-action SUPPRESS \
    --user-attributes "${ATTRS[@]}" >/dev/null
fi

# 2) password permanente
aws cognito-idp admin-set-user-password \
  --user-pool-id "$POOL" --region "$REG" \
  --username "$USERNAME" \
  --password "$PASS" \
  --permanent >/dev/null
echo "Password impostata."

# 3) tenant_ids
aws cognito-idp admin-update-user-attributes \
  --user-pool-id "$POOL" --region "$REG" --username "$USERNAME" \
  --user-attributes "[{\"Name\":\"custom:tenant_ids\",\"Value\":\"${TENANTS_JSON//\"/\\\"}\"}]" >/dev/null
echo "tenant_ids aggiornato."

# 4) gruppi
OTHER=$([[ "$GROUP" == "ADMIN" ]] && echo "USER" || echo "ADMIN" || echo "ADMIN_DASHBOARD" )
aws cognito-idp admin-remove-user-from-group \
  --user-pool-id "$POOL" --region "$REG" --username "$USERNAME" \
  --group-name "$OTHER" >/dev/null 2>&1 || true
aws cognito-idp admin-add-user-to-group \
  --user-pool-id "$POOL" --region "$REG" --username "$USERNAME" \
  --group-name "$GROUP" >/dev/null 2>&1 || true
echo "Gruppo assegnato: $GROUP"

# 5) riepilogo
aws cognito-idp admin-get-user --user-pool-id "$POOL" --username "$USERNAME" --region "$REG" \
  --query '{Username:Username,Email:Attributes[?Name==`email`]|[0].Value,Name:Attributes[?Name==`name`]|[0].Value,TenantIds:Attributes[?Name==`custom:tenant_ids`]|[0].Value}' --output json
aws cognito-idp admin-list-groups-for-user --user-pool-id "$POOL" --username "$USERNAME" --region "$REG" \
  --query 'Groups[].GroupName' --output json
echo "Fatto."