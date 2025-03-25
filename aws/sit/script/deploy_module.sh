#!/bin/bash
set -e

# Determina il percorso assoluto della cartella base (una directory sopra lo script)
BASE_DIR="$(dirname "$(readlink -f "$0")")/.."

# Carica le variabili da BASE_DIR/env/deploy.env
if [[ -f "$BASE_DIR/env/deploy.env" ]]; then
  source "$BASE_DIR/env/deploy.env"
else
  echo "Errore: File deploy.env non trovato in $BASE_DIR/env"
  exit 1
fi

# Recupera il nome del modulo passato come primo argomento
MODULO=$1

if [[ -z "$MODULO" ]]; then
  echo "Errore: nessun modulo specificato. Specificare un modulo o 'all' per deployare tutto."
  exit 1
fi

echo "=== Inizio deploy di $MODULO $(date) ==="

# Funzione per verificare se Keycloak è in esecuzione
check_keycloak() {
  docker ps | grep -q "keycloak-auxdromos"
  return $?
}

# Funzione per verificare se un'immagine esiste su ECR
check_image_exists() {
  local MODULE_NAME=$1
  local REPOSITORY="auxdromos-${MODULE_NAME}"

  echo "Verifico esistenza dell'immagine $REPOSITORY su ECR..."

  # Verifica se il repository esiste su ECR
  if ! aws ecr describe-repositories --repository-names "$REPOSITORY" &>/dev/null; then
    echo "Repository $REPOSITORY non esiste su ECR"
    return 1
  fi

  # Verifica se ci sono immagini nel repository
  local IMAGE_COUNT
  IMAGE_COUNT=$(aws ecr describe-images --repository-name "$REPOSITORY" --query "length(imageDetails)" --output text)

  if [ "$IMAGE_COUNT" -eq "0" ]; then
    echo "Repository $REPOSITORY esiste ma non contiene immagini"
    return 1
  fi

  echo "Repository $REPOSITORY trovato con $IMAGE_COUNT immagini"
  return 0
}

# Funzione per effettuare il deploy di Keycloak e il setup
deploy_keycloak() {
  echo "===== Deploying Keycloak... ====="

  # Assicura che la rete esista
  docker network create auxdromos-network 2>/dev/null || true

  # Verifica se keycloak.env esiste e carica le sue variabili
  if [[ ! -f "$BASE_DIR/env/keycloak.env" ]]; then
    echo "ERRORE: File keycloak.env non trovato in $BASE_DIR/env"
    exit 1
  fi

  source "$BASE_DIR/env/keycloak.env"
  if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_PASSWORD" || -z "$KEYCLOAK_ADMIN" || -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
    echo "ERRORE: Variabili di ambiente mancanti nel file keycloak.env"
    exit 1
  fi

  # Deploy di Keycloak usando il file docker-compose specifico
  docker-compose -f "$BASE_DIR/docker/docker-compose-keycloak.yml" up -d

  # Verifica che il container sia partito
  if ! docker ps | grep -q "auxdromos-keycloak"; then
    echo "ERRORE: Il container di Keycloak non è stato avviato correttamente"
    docker logs auxdromos-keycloak
    exit 1
  fi

  echo "Deploy di Keycloak completato!"
  echo "Attesa per l'avvio di Keycloak..."
  sleep 10

  # Controlla periodicamente se Keycloak è pronto
  ATTEMPTS=0
  MAX_ATTEMPTS=12  # 2 minuti in totale (12 * 10 secondi)
  while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:${EXTERNAL_PORT}/health | grep -q "200"; then
      echo "Keycloak è pronto!"
      break
    fi
    echo "Attendi... ($ATTEMPTS/$MAX_ATTEMPTS)"
    ATTEMPTS=$((ATTEMPTS + 1))
    sleep 10
  done

  if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "ERRORE: Timeout nell'attesa che Keycloak diventasse pronto"
    exit 1
  fi

  # Esecuzione dello script di setup di Keycloak
  echo "Esecuzione dello script di setup di Keycloak..."
  bash "$BASE_DIR/aws/sit/setup/keycloak-setup.sh"
  echo "Setup di Keycloak completato!"
}

# Funzione per effettuare il deploy di un modulo
deploy_module() {
  local MODULE_NAME=$1
  echo "===== Deploying $MODULE_NAME... ====="

  # Verifica se l'immagine per questo modulo esiste
  if ! check_image_exists "$MODULE_NAME"; then
    echo "Attenzione: Nessuna immagine trovata per il modulo $MODULE_NAME su ECR. Il deployment sarà saltato."
    return 0
  fi

  # Recupera l'ultima versione stabile del modulo da ECR
  LATEST_VERSION=$(aws ecr describe-images --repository-name "auxdromos-${MODULE_NAME}" \
                   --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' \
                   --output text | grep -v null)

  if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "None" ]]; then
    echo "Errore: impossibile recuperare la versione per $MODULE_NAME"
    exit 1
  fi

  echo "Ultima versione per $MODULE_NAME è $LATEST_VERSION"

  # Inserire qui eventuali operazioni di deploy specifiche per il modulo
  echo "Deploy del modulo $MODULE_NAME completato!"
}

# Gestione del deploy basata sul modulo specificato
if [[ "$MODULO" == "keycloak" ]]; then
  deploy_keycloak
elif [[ "$MODULO" == "all" ]]; then
  deploy_keycloak
  # Aggiungere qui eventuali altri moduli
  # deploy_module "nome_modulo"
else
  deploy_module "$MODULO"
fi

echo "=== Deploy completato $(date) ==="