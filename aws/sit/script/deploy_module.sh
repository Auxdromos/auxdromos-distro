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

# Funzione per effettuare il deploy di un modulo
deploy_module() {
  local MODULE_NAME=$1
  echo "Deploying $MODULE_NAME..."

  # Recupera l'ultima versione stabile del modulo da S3
  LATEST_VERSION=$(aws s3 ls s3://$S3_BUCKET_NAME/$MODULE_NAME/ | awk '{print $4}' | grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.jar$" | sort | tail -n 1 | sed 's/.*\([0-9]\+\.[0-9]\+\.[0-9]\+\).*/\1/')

  if [[ -z "$LATEST_VERSION" ]]; then
    echo "Errore: impossibile recuperare la versione più recente per $MODULE_NAME."
    exit 1
  fi

  echo "Ultima versione trovata per $MODULE_NAME: $LATEST_VERSION"

  # Scarica il JAR aggiornato
  echo "Scaricando il JAR aggiornato da S3..."
  aws s3 cp s3://$S3_BUCKET_NAME/$MODULE_NAME/$MODULE_NAME-$LATEST_VERSION-AWS.jar $EC2_APP_DIR/

  # Pull dell'ultima immagine Docker
  echo "Scaricando l'ultima immagine Docker..."
  docker pull $AWS_ACCOUNT_ID.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/$MODULE_NAME:$LATEST_VERSION

  # Aggiorna il docker-compose.yml con la nuova versione
  echo "Aggiornando il docker-compose.yml..."
  sed -i "s/latest/$LATEST_VERSION/g" "$BASE_PATH/docker/docker-compose.yml"

  # Esegue il deploy del modulo tramite docker-compose
  echo "Avviando il servizio $MODULE_NAME..."
  docker-compose -f "$BASE_PATH/docker/docker-compose.yml" up -d --build

  echo "Deploy di $MODULE_NAME completato!"
}

# Verifica se si deve deployare tutti i moduli o solo uno specifico
if [[ "$MODULO" == "all" ]]; then
  for mod in $MODULES; do
    deploy_module "$mod"
  done
else
  deploy_module "$MODULO"
fi