#!/bin/bash

# Carica le variabili da ../env/deploy.env
if [[ -f "../env/deploy.env" ]]; then
  source "../env/deploy.env"
else
  echo "Errore: File deploy.env non trovato in ../env"
  exit 1
fi

MODULO=$1

if [[ -z "$MODULO" ]]; then
  echo "Errore: nessun modulo specificato. Specificare un modulo o 'all' per deployare tutto."
  exit 1
fi

# Funzione per verificare se Keycloak è in esecuzione
check_keycloak() {
  docker ps | grep -q "keycloak-auxdromos"
  return $?
}

# Funzione per verificare se un'immagine esiste su ECR
check_image_exists() {
  local MODULE_NAME=$1
  local REPOSITORY="auxdromos-${MODULE_NAME}"

  # Verifica se il repository esiste su ECR
  aws ecr describe-repositories --repository-names "$REPOSITORY" &>/dev/null

  if [ $? -ne 0 ]; then
    # Repository non esiste
    return 1
  fi

  # Verifica se ci sono immagini nel repository
  local IMAGE_COUNT=$(aws ecr describe-images --repository-name "$REPOSITORY" --query "length(imageDetails)" --output text)

  if [ "$IMAGE_COUNT" -eq "0" ]; then
    # Repository esiste ma è vuoto
    return 1
  fi

  # Immagine esiste
  return 0
}

# Funzione per deployare Keycloak e eseguire il setup
deploy_keycloak() {
  echo "Deploying Keycloak..."

  # Assicurati che la rete esista
  docker network create auxdromos-network 2>/dev/null || true

  # Deploy di Keycloak usando il file docker-compose specifico
  docker-compose -f "$BASE_PATH/docker/docker-compose-keycloak.yml" up -d

  echo "Deploy di Keycloak completato!"

  # Aspetta che Keycloak sia pronto
  echo "Attesa per l'avvio di Keycloak..."
  sleep 30

  # Esegui lo script di setup di Keycloak
  echo "Esecuzione dello script di setup di Keycloak..."
  bash aws/sit/setup/keycloak-setup.sh

  echo "Setup di Keycloak completato!"
}

# Funzione per effettuare il deploy di un modulo
deploy_module() {
  local MODULE_NAME=$1
  echo "Deploying $MODULE_NAME..."

  # Verifica se l'immagine per questo modulo esiste
  if ! check_image_exists "$MODULE_NAME"; then
    echo "Attenzione: Nessuna immagine trovata per il modulo $MODULE_NAME su ECR. Il deployment sarà saltato."
    return 0
  fi

  # Recupera l'ultima versione stabile del modulo da ECR
  LATEST_VERSION=$(aws ecr describe-images --repository-name "auxdromos-${MODULE_NAME}" --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text | grep -v null)

  if [[ -z "$LATEST_VERSION" || "$LATEST_VERSION" == "None" ]]; then
    echo "Errore: impossibile recuperare la versione più recente per $MODULE_NAME."
    return 1
  fi

  echo "Ultima versione trovata per $MODULE_NAME: $LATEST_VERSION"

  # Pull dell'ultima immagine Docker
  echo "Scaricando l'ultima immagine Docker..."
  docker pull $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/auxdromos-$MODULE_NAME:$LATEST_VERSION

  # Imposta le variabili per il docker-compose
  export MODULO=$MODULE_NAME
  export VERSION=$LATEST_VERSION

  # Carica le configurazioni specifiche del modulo
  if [[ -f "$BASE_PATH/env/$MODULE_NAME.env" ]]; then
    source "$BASE_PATH/env/$MODULE_NAME.env"
  fi

  # Esegue il deploy del modulo tramite docker-compose
  echo "Avviando il servizio $MODULE_NAME..."
  docker-compose -f "$BASE_PATH/docker/docker-compose.yml" up -d

  echo "Deploy di $MODULE_NAME completato!"
}

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
    for mod in $MODULE_ORDER; do
      deploy_module "$mod"
    done
  else
    # Altrimenti usa l'elenco standard dei moduli
    for mod in $MODULES; do
      deploy_module "$mod"
    done
  fi
else
  # Deploy di un singolo modulo
  deploy_module "$MODULO"
fi