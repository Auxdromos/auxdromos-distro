#!/bin/bash
set -e

 # Carica le variabili d'ambiente dal file .env se esiste
 if [ -f /Users/mbranca/Work/AuxDromos/auxdromos-idp/docker/.env ]; then
   source /Users/mbranca/Work/AuxDromos/auxdromos-idp/docker/.env
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

# Funzione per creare il realm
create_realm() {
  local token="$1"
  echo "Creating realm: ${KEYCLOAK_AUXDROMOS_REALM} ..."
  response=$(curl -s -o temp/response.json -w "%{http_code}" -X POST \
    "${KEYCLOAK_BASE_URL}/admin/realms" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"realm\": \"${KEYCLOAK_AUXDROMOS_REALM}\", \"enabled\": true}")

  http_code=$(tail -n1 <<< "$response")
  response_body=$(cat temp/response.json)

  echo "HTTP Response Code: $http_code"
  echo "Response Body: $response_body"

  if [[ "$http_code" -eq 201 ]]; then
    echo "Realm '${KEYCLOAK_AUXDROMOS_REALM}' created successfully."
  elif [[ "$http_code" -eq 409 ]]; then
    echo "Realm '${KEYCLOAK_AUXDROMOS_REALM}' already exists or conflict occurred: $response_body"
  else
    echo "Error: Unable to create realm '${KEYCLOAK_AUXDROMOS_REALM}'. Exiting."
    exit 1
  fi
}

# Funzione per creare il client
create_client() {
  local token="$1"
  echo "Creating client: ${KEYCLOAK_AUXDROMOS_CLIENT} ..."
  response=$(curl -s -o temp/response.json -w "%{http_code}" -X POST \
    "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/clients" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{
      \"clientId\": \"${KEYCLOAK_AUXDROMOS_CLIENT}\",
      \"enabled\": true,
      \"directAccessGrantsEnabled\": true,
      \"publicClient\": false,
      \"secret\": \"${KEYCLOAK_AUXDROMOS_CLIENT_SECRET}\",
      \"redirectUris\": [${KEYCLOAK_AUXDROMOS_REDIRECT_URIS}]
    }")

  http_code=$(tail -n1 <<< "$response")
  response_body=$(cat temp/response.json)

  echo "HTTP Response Code: $http_code"
  echo "Response Body: $response_body"

  if [[ "$http_code" -eq 201 ]]; then
    echo "Client '${KEYCLOAK_AUXDROMOS_CLIENT}' created successfully."
  elif [[ "$http_code" -eq 409 ]]; then
    echo "Client '${KEYCLOAK_AUXDROMOS_CLIENT}' already exists or conflict occurred: $response_body"
  else
    echo "Error: Unable to create client '${KEYCLOAK_AUXDROMOS_CLIENT}'. Exiting."
    exit 1
  fi
}

# Function to create a role
create_role() {
  # shellcheck disable=SC3043
  local token="$1"
  # shellcheck disable=SC3043
  local role_name="$2"
  response=$(curl -s -o temp/response.json -w "%{http_code}" -X POST \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/roles" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${role_name}\"}")

 # Extract the HTTP response code
  http_code=$(tail -n1 <<< "$response")

  # Extract the response body (saved in temp/response.json)
  response_body=$(cat temp/response.json)

  # Print both the HTTP code and response body
  echo "HTTP Response Code: $http_code"
  echo "Response Body: $response_body"

  # Handle different response codes
  if [[ "$http_code" -eq 201 ]]; then
    echo "Role '${role_name}' created successfully."
  elif [[ "$http_code" -eq 409 ]]; then
    echo "Conflict to create role '${role_name}': $response_body"
  else
    echo "Error: Unable to create role '${role_name}'."
    echo "Unexpected Response ($http_code): $response_body"
    exit 1
  fi
}

# Function to create user and assign roles
create_user() {
  # shellcheck disable=SC3043
  local token="$1"
  # shellcheck disable=SC3043
  local user_data="$2"

  # Extract user fields from JSON using shell utilities
  USERNAME=$(echo $user_data | grep -o '"username":"[^"]*' | sed 's/"username":"//')
  EMAIL=$(echo $user_data | grep -o '"email":"[^"]*' | sed 's/"email":"//')
  PASSWORD=$(echo $user_data | grep -o '"password":"[^"]*' | sed 's/"password":"//')
  FIRST_NAME=$(echo $user_data | grep -o '"firstName":"[^"]*' | sed 's/"firstName":"//')
  LAST_NAME=$(echo $user_data | grep -o '"lastName":"[^"]*' | sed 's/"lastName":"//')
  TENANT_ID=$(echo $user_data | grep -o '"tenantId":"[^"]*' | sed 's/"tenantId":"//')
  ROLE=$(echo $user_data | grep -o '"roles":\[.*\]' | sed 's/"roles":\[\(.*\)\]/\1/' | tr -d '[]"')

  echo "User '${USERNAME}' creating."

  # Create the user
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

 # Extract the HTTP response code
  http_code=$(tail -n1 <<< "$response")

  # Extract the response body (saved in temp/response.json)
  response_body=$(cat temp/response.json)

  # Print both the HTTP code and response body
  echo "HTTP Response Code: $http_code"
  echo "Response Body: $response_body"

  # Handle different response codes
  if [[ "$http_code" -eq 201 ]]; then
    echo "User '${USERNAME}' created successfully."
  elif [[ "$http_code" -eq 409 ]]; then
    echo "Conflict to create user '${USERNAME}': $response_body"
  else
    echo "Error: Unable to create user '${USERNAME}'."
    echo "Unexpected Response ($http_code): $response_body"
    exit 1
  fi

  # Fetch user ID
  USER_ID=$(curl -s -X GET \
    "${KEYCLOAK_URL}/admin/realms/${KEYCLOAK_AUXDROMOS_REALM}/users?username=${USERNAME}" \
    -H "Authorization: Bearer ${token}" | grep -o '"id":"[^"]*' | sed 's/"id":"//')

  # Assign roles to the user
  for role in $(echo $ROLE | tr ',' ' '); do
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

  echo "Creating realm '${KEYCLOAK_AUXDROMOS_REALM}'..."
  create_realm "$TOKEN"
  echo "Real '${KEYCLOAK_AUXDROMOS_REALM}' created successfully."

  echo "Creating client '${KEYCLOAK_AUXDROMOS_CLIENT}'..."
  create_client "$TOKEN"
  echo "Client '${KEYCLOAK_AUXDROMOS_CLIENT}' created successfully."

  echo "Creating roles..."
  create_role "$TOKEN" "$KEYCLOAK_AUXDROMOS_ADMIN_ROLE"
  create_role "$TOKEN" "$KEYCLOAK_AUXDROMOS_USER_ROLE"
  echo "Roles created successfully."

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