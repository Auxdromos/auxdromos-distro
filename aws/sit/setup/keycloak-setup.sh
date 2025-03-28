#!/bin/bash
set -e

 # Carica le variabili d'ambiente dal file .env se esiste
if [ -f aws/sit/setup/.env ]; then
  source aws/sit/setup/.env
fi

# Cambia la directory se non sei già in "keycloak"
if [ "$(basename "$PWD")" != "keycloak" ]; then
  echo "Changing directory to keycloak folder..."
  cd "$(dirname "$0")" || { echo "Error: Unable to change to keycloak directory."; exit 1; }
fi

# Validazione delle variabili d'ambiente richieste
REQUIRED_VARS=("KEYCLOAK_URL" "KEYCLOAK_ADMIN" "KEYCLOAK_ADMIN_PASSWORD" "KEYCLOAK_AUXDROMOS_REALM" "KEYCLOAK_AUXDROMOS_CLIENT" "KEYCLOAK_AUXDROMOS_CLIENT_SECRET" "KEYCLOAK_AUXDROMOS_REDIRECT_URIS")
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: Environment variable ${var} is not set. Exiting."
    exit 1
  fi
done

echo "All required environment variables are set."

# Imposta i parametri utilizzando le variabili d’ambiente
KEYCLOAK_BASE_URL="${KEYCLOAK_URL}"
# Le altre variabili (ADMIN_USERNAME, KEYCLOAK_ADMIN_PASSWORD, ecc.) vengono ereditate dall'ambiente

# Crea la cartella per i file temporanei
mkdir -p temp

# Percorso del file JSON originale del realm
REALM_JSON_FILE="/Users/mbranca/Work/AuxDromos/auxdromos-idp/docker/script/realm-export.json"

if [ ! -f "$REALM_JSON_FILE" ]; then
  echo "Errore: il file '$REALM_JSON_FILE' non esiste."
  exit 1
fi

# Modifica il file JSON per aggiornare il client secret per il client auxdromos-cli
# Si assume che l'attributo contenente il secret si chiami "secret" all'interno
# dell'oggetto client. Se la struttura JSON prevede una configurazione diversa,
# sarà necessario modificare il filtro jq.
UPDATED_REALM_JSON="temp/realm-export-updated.json"
if command -v jq >/dev/null 2>&1; then
    jq --arg clientId "${KEYCLOAK_AUXDROMOS_CLIENT}" --arg newSecret "${KEYCLOAK_AUXDROMOS_CLIENT_SECRET}" '
      (.clients[] | select(.clientId == $clientId)).secret = $newSecret
    ' "$REALM_JSON_FILE" > "$UPDATED_REALM_JSON"
    echo "Updated realm JSON file with new client secret for client ${KEYCLOAK_AUXDROMOS_CLIENT}."
else
    echo "jq non è installato. Non è possibile aggiornare il client secret automaticamente, utilizzo il file originale."
    cp "$REALM_JSON_FILE" "$UPDATED_REALM_JSON"
fi

# Ciclo di retry per verificare la disponibilità di Keycloak
MAX_RETRIES=10
RETRY_INTERVAL=10
retry_count=0

echo "Checking availability of Keycloak at ${KEYCLOAK_BASE_URL}..."
until curl -sv ${KEYCLOAK_BASE_URL} 2>&1 | grep -q "Location: ${KEYCLOAK_BASE_URL}/admin/"; do
  retry_count=$((retry_count+1))
  if [ ${retry_count} -ge ${MAX_RETRIES} ]; then
    echo "Keycloak not available after ${MAX_RETRIES} attempts. Exiting."
    exit 1
  fi
  echo "Attempt ${retry_count}/${MAX_RETRIES}: Keycloak not responding. Waiting ${RETRY_INTERVAL} seconds..."
  sleep ${RETRY_INTERVAL}
done


echo "Keycloak is available; proceeding with configuration setup..."

# Funzione per ottenere il token di accesso
get_access_token() {
  TOKEN=$(curl -s -X POST \
    "${KEYCLOAK_BASE_URL}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" | grep -o '"access_token":"[^"]*' | sed 's/"access_token":"//')

  if [ -z "$TOKEN" ]; then
    echo "Error: Unable to get access token. Check your credentials."
    exit 1
  fi

  echo "$TOKEN"
}

create_realm() {
  local token="$1"

  echo "Aggiorno il realm '${KEYCLOAK_AUXDROMOS_REALM}' utilizzando il file $REALM_JSON_FILE..."
  update_response=$(curl -s -w "\n%{http_code}" -X PUT "$KEYCLOAK_URL/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    --data-binary "@$REALM_JSON_FILE")

  http_code=$(echo "$update_response" | tail -n 1)
  response_body=$(echo "$update_response" | sed '$d')

  echo "PUT HTTP Code: $http_code"
  echo "PUT Response Body: $response_body"

  if [ "$http_code" -eq 204 ]; then
    echo "Realm '${KEYCLOAK_AUXDROMOS_REALM}' updated successfully."
  elif [ "$http_code" -eq 404 ]; then
    echo "Realm '${KEYCLOAK_AUXDROMOS_REALM}' non trovato. Procedo a crearlo..."
    create_response=$(curl -s -w "\n%{http_code}" -X POST "$KEYCLOAK_URL/admin/realms" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${token}" \
    --data-binary "@$REALM_JSON_FILE")
    create_http_code=$(echo "$create_response" | tail -n 1)
    create_response_body=$(echo "$create_response" | sed '$d')
    echo "POST HTTP Code: $create_http_code"
    echo "POST Response Body: $create_response_body"

    if [ "$create_http_code" -eq 201 ]; then
      echo "Realm '${KEYCLOAK_AUXDROMOS_REALM}' created successfully."
    else
      echo "Error: Unable to create realm '${KEYCLOAK_AUXDROMOS_REALM}'."
      exit 1
    fi
  else
    echo "Error: Unable to update realm '${KEYCLOAK_AUXDROMOS_REALM}'."
    exit 1
  fi
}

# Function to create user and assign roles
create_user() {
  # Input:
  # $1 token amministrativo
  # $2 dati utente in formato JSON

  local token="$1"
  local user_data="$2"

  # Estrai i campi dall'input JSON (utilizzando grep e sed)
  USERNAME=$(echo "$user_data" | grep -o '"username":"[^"]*' | sed 's/"username":"//')
  EMAIL=$(echo "$user_data" | grep -o '"email":"[^"]*' | sed 's/"email":"//')
  PASSWORD=$(echo "$user_data" | grep -o '"password":"[^"]*' | sed 's/"password":"//')
  FIRST_NAME=$(echo "$user_data" | grep -o '"firstName":"[^"]*' | sed 's/"firstName":"//')
  LAST_NAME=$(echo "$user_data" | grep -o '"lastName":"[^"]*' | sed 's/"lastName":"//')
  TENANT_ID=$(echo "$user_data" | grep -o '"tenantId":"[^"]*' | sed 's/"tenantId":"//')
  ROLE=$(echo "$user_data" | grep -o '"roles":\[.*\]' | sed 's/"roles":\[\(.*\)\]/\1/' | tr -d '[]"')

  echo "User '${USERNAME}' creating."

  # Crea l'utente con i campi base e includi l'attributo tenantId
  response=$(curl -s -o temp/response.json -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/users" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{
      \"username\": \"${USERNAME}\",
      \"email\": \"${EMAIL}\",
      \"firstName\": \"${FIRST_NAME}\",
      \"lastName\": \"${LAST_NAME}\",
      \"credentials\": [{\"type\": \"password\", \"value\": \"${PASSWORD}\", \"temporary\": false}],
      \"enabled\": true,
      \"emailVerified\": true,
      \"attributes\": {
        \"tenantId\": [\"${TENANT_ID}\"]
      }
    }")

  http_code=$(tail -n1 <<< "$response")
  response_body=$(cat temp/response.json)

  echo "HTTP Response Code: $http_code"
  echo "Response Body: $response_body"

  if [[ "$http_code" -eq 201 ]]; then
    echo "User '${USERNAME}' created successfully."
  elif [[ "$http_code" -eq 409 ]]; then
    echo "Conflict to create user '${USERNAME}': $response_body"
  else
    echo "Error: Unable to create user '${USERNAME}'."
    echo "Unexpected Response ($http_code): $response_body"
    exit 1
  fi

  # Recupera l'ID dell'utente appena creato
  USER_ID=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/users?username=${USERNAME}" \
    -H "Authorization: Bearer ${token}" | grep -o '"id":"[^"]*' | sed 's/"id":"//')

  if [ -z "$USER_ID" ]; then
    echo "Errore: impossibile recuperare l'ID dell'utente ${USERNAME}."
    exit 1
  fi

  echo "User ID: $USER_ID"

  # Aggiorna l'attributo tenantId per l'utente (in caso sia necessario forzare l'aggiornamento)
  echo "Aggiorno gli attributi dell'utente $USER_ID..."
  update_payload=$(cat <<EOF
{
  "email": "${EMAIL}",
  "firstName": "${FIRST_NAME}",
  "lastName": "${LAST_NAME}",
  "attributes": {
    "tenantId": ["${TENANT_ID}"]
  }
}
EOF
)
  update_response=$(curl -s -w "\n%{http_code}" -X PUT "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/users/${USER_ID}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${token}" \
    -d "$update_payload")
  update_http_code=$(echo "$update_response" | tail -n 1)
  update_response_body=$(echo "$update_response" | sed '$d')

  echo "Update user attributes HTTP Code: $update_http_code"
  echo "Update user attributes Response: $update_response_body"

  if [[ "$update_http_code" -ne 204 ]]; then
    echo "Warning: User attribute update did not return expected HTTP 204."
  fi

  # Assegna i ruoli all'utente
  for role in $(echo "$ROLE" | tr ',' ' '); do
    ROLE_ID=$(curl -s -X GET \
      "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/roles/${role}" \
      -H "Authorization: Bearer ${token}" | grep -o '"id":"[^"]*' | sed 's/"id":"//')

    curl -s -X POST \
      "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/users/${USER_ID}/role-mappings/realm" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -d "[{\"id\": \"${ROLE_ID}\", \"name\": \"${role}\"}]" >/dev/null

    echo "Role '${role}' assigned to user '${USERNAME}'."
  done
}


# Main function to setup Keycloak
setup_keycloak() {
  echo "Getting admin access token..."
  TOKEN=$(get_access_token)

  create_realm $TOKEN

  echo "Creating users from file '${KEYCLOAK_AUXDROMOS_USERS_FILE}'..."
  if [ ! -f "$KEYCLOAK_AUXDROMOS_USERS_FILE" ]; then
    echo "Error: Users file '${KEYCLOAK_AUXDROMOS_USERS_FILE}' not found!"
    exit 1
  fi

  while IFS= read -r line; do
    # Read JSON objects line by line and create each user
    echo "Create_user "
    if [ -n "$line" ]; then
      create_user "$TOKEN" "$line"
    else
      echo "Warning: Empty line detected in users file."
    fi
  done < <(jq -c '.[]' "$KEYCLOAK_AUXDROMOS_USERS_FILE") # Extract JSON objects

  echo "Keycloak setup complete."
}

# Start the setup
setup_keycloak