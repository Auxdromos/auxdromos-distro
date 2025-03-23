#!/bin/bash

# Carica le variabili da ../env/deploy.env
if [[ -f "./env/deploy.env" ]]; then
  source "./env/deploy.env"
else
  echo "Errore: File deploy.env non trovato in ./env"
  exit 1
fi

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

# Funzione per verificare se un'immagine esiste su ECR con miglior gestione degli errori
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
  local IMAGE_COUNT=$(aws ecr describe-images --repository-name "$REPOSITORY" --query "length(imageDetails)" --output text)

  if [ "$IMAGE_COUNT" -eq "0" ]; then
    echo "Repository $REPOSITORY esiste ma non contiene immagini"
    return 1
  fi

  echo "Repository $REPOSITORY trovato con $IMAGE_COUNT immagini"
  return 0
}

# Funzione migliorata per deployare Keycloak e eseguire il setup
deploy_keycloak() {
  echo "===== Deploying Keycloak... ====="

  # Assicurati che la rete esista
  docker network create auxdromos-network 2>/dev/null || true

  # Verifica se keycloak.env esiste
  if [[ ! -f "./env/keycloak.env" ]]; then
    echo "ERRORE: File keycloak.env non trovato in ./env"
    exit 1
  fi

  # Verifica che le variabili necessarie siano presenti
  source ./env/keycloak.env
  if [[ -z "$POSTGRES_USER" || -z "$POSTGRES_PASSWORD" || -z "$KEYCLOAK_ADMIN" || -z "$KEYCLOAK_ADMIN_PASSWORD" ]]; then
    echo "ERRORE: Variabili di ambiente mancanti nel file keycloak.env"
    exit 1
  fi

  # Deploy di Keycloak usando il file docker-compose specifico
  docker-compose -f "./docker/docker-compose-keycloak.yml" up -d

  # Verifica che il container sia partito
  if ! docker ps | grep -q "auxdromos-keycloak"; then
    echo "ERRORE: Il container di Keycloak non è stato avviato correttamente"
    docker logs auxdromos-keycloak
    exit 1
  fi

  echo "Deploy di Keycloak completato!"

  # Aspetta che Keycloak sia pronto
  echo "Attesa per l'avvio di Keycloak..."
  sleep 10

  # Controlla periodicamente se Keycloak è pronto
  ATTEMPTS=0
  MAX_ATTEMPTS=12  # 2 minuti (12 * 10 secondi)

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

  # Esegui lo script di setup di Keycloak
  echo "Esecuzione dello script di setup di Keycloak..."
  bash ./aws/sit/setup/keycloak-setup.sh

  echo "Setup di Keycloak completato!"
}

# Funzione migliorata per effettuare il deploy di un modulo
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
    echo "Errore: impossibile recuperare la versione più recente per $MODULE_NAME."
    return 1
  fi

  echo "Ultima versione trovata per $MODULE_NAME: $LATEST_VERSION"

  # Pull dell'ultima immagine Docker con gestione errori
  echo "Scaricando l'ultima immagine Docker..."
  if ! docker pull $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/auxdromos-$MODULE_NAME:$LATEST_VERSION; then
    echo "ERRORE: Impossibile scaricare l'immagine Docker per $MODULE_NAME:$LATEST_VERSION"
    return 1
  fi

  # Verifica esistenza del file env del modulo
  if [[ ! -f "./env/$MODULE_NAME.env" ]]; then
    echo "ERRORE: File di configurazione ./env/$MODULE_NAME.env non trovato"
    return 1
  fi

  # Imposta le variabili per il docker-compose
  export MODULO=$MODULE_NAME
  export VERSION=$LATEST_VERSION

  # Carica le configurazioni specifiche del modulo
  source "./env/$MODULE_NAME.env"

  # Verifica che le porte siano specificate
  if [[ -z "$EXTERNAL_PORT" || -z "$INTERNAL_PORT" ]]; then
    echo "ERRORE: Porta esterna o interna non specificata in ./env/$MODULE_NAME.env"
    return 1
  fi

  # Esegue il deploy del modulo tramite docker-compose
  echo "Avviando il servizio $MODULE_NAME..."
  docker-compose -f "./docker/docker-compose.yml" up -d

  # Verifica che il container sia partito
  if ! docker ps | grep -q "auxdromos-$MODULE_NAME"; then
    echo "ERRORE: Il container di $MODULE_NAME non è stato avviato correttamente"
    docker logs auxdromos-$MODULE_NAME
    return 1
  fi

  echo "Deploy di $MODULE_NAME completato!"
  return 0
}

# Verifica se docker e docker-compose sono installati
if ! command -v docker &> /dev/null || ! command -v docker-compose &> /dev/null; then
  echo "ERRORE: docker o docker-compose non sono installati"
  exit 1
fi

# Verifica se aws cli è configurato
if ! aws sts get-caller-identity &> /dev/null; then
  echo "ERRORE: AWS CLI non configurato correttamente"
  exit 1
fi

# Prima verifica se Keycloak è già in esecuzione
if ! check_keycloak; then
  echo "Keycloak non è in esecuzione, verrà deployato..."
  deploy_keycloak
fi

# Controlla se è un "deploy all" o di un singolo modulo
if [[ "$MODULO" == "all" ]]; then
  # Per il deploy di tutti i moduli, usa l'ordine specificato in $MODULE_ORDER se disponibile
  if [[ -n "$MODULE_ORDER" ]]; then
    echo "Esecuzione del deploy dei moduli nell'ordine specificato..."
    FAILED_MODULES=""
    for mod in $MODULE_ORDER; do
      if ! deploy_module "$mod"; then
        FAILED_MODULES="$FAILED_MODULES $mod"
      fi
    done

    if [[ -n "$FAILED_MODULES" ]]; then
      echo "AVVISO: I seguenti moduli hanno fallito il deploy: $FAILED_MODULES"
      exit 1
    fi
  else
    # Altrimenti usa l'elenco standard dei moduli
    FAILED_MODULES=""
    for mod in $MODULES; do
      if ! deploy_module "$mod"; then
        FAILED_MODULES="$FAILED_MODULES $mod"
      fi
    done

    if [[ -n "$FAILED_MODULES" ]]; then
      echo "AVVISO: I seguenti moduli hanno fallito il deploy: $FAILED_MODULES"
      exit 1
    fi
  fi
else
  # Deploy di un singolo modulo
  deploy_module "$MODULO" || exit 1
fi

echo "=== Deploy completato con successo $(date) ==="