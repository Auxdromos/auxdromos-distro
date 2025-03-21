#!/bin/bash

# Script per scaricare ed eseguire localmente la versione più recente di uno o più moduli da S3.
# Uso: ./download_and_run_local.sh [<nome_modulo> [<versione_specifica>]]

MODULE_NAME=$1
SPECIFIC_VERSION=$2

# Configurazione AWS
AWS_REGION="us-east-1"
S3_BUCKET="auxdromos-artifacts"

# Verifica credenziali AWS
if ! aws sts get-caller-identity &>/dev/null; then
  echo "Errore: AWS CLI non configurato correttamente. Eseguire 'aws configure'."
  exit 1
fi

# Lista di moduli di default se non viene specificato alcun nome di modulo
MODULES="module1 module2 module3"  # Sostituisci con i tuoi moduli

# Funzione per verificare se un modulo è presente nella lista
module_exists() {
  local MODULE=$1
  for M in $MODULES; do
    if [[ "$M" == "$MODULE" ]]; then
      return 0  # Modulo trovato
    fi
  done
  return 1  # Modulo non trovato
}


# Funzione per scaricare ed eseguire un modulo
download_and_run() {
  local MODULE=$1
  local VERSION=$2

  # Crea directory temporanea
  TEMP_DIR="./temp_$MODULE"
  mkdir -p $TEMP_DIR

  # Download degli artefatti
  echo "Download degli artefatti per $MODULE versione $VERSION..."
  aws s3 cp --recursive s3://$S3_BUCKET/$MODULE/$VERSION/ $TEMP_DIR/

  if [[ $? -ne 0 ]]; then
    echo "Errore: Download degli artefatti fallito"
    rm -rf $TEMP_DIR
    return 1
  fi

  # Trova il JAR principale
  MAIN_JAR=$(find $TEMP_DIR -name "*.jar" -not -name "*-sources.jar" -not -name "*-javadoc.jar" | head -n 1)

  if [[ -z "$MAIN_JAR" ]]; then
    echo "Errore: Nessun JAR trovato nei file scaricati"
    rm -rf $TEMP_DIR
    return 1
  fi

  echo "JAR trovato: $MAIN_JAR"

  # Avvio del container Docker
  echo "Avvio del container Docker..."
  docker run -it --rm \
    -v "$PWD/$TEMP_DIR:/app" \
    -p 8080:8080 \
    --name auxdromos-$MODULE-local \
    --network auxdromos-network \
    amazoncorretto:17 \
    java -jar "/app/$(basename $MAIN_JAR)"

  # Pulizia
  echo "Pulizia dei file temporanei..."
  rm -rf $TEMP_DIR
}


# Gestisci il caso in cui non viene passato alcun nome di modulo
if [[ -z "$MODULE_NAME" ]]; then
  echo "Nessun modulo specificato. Esecuzione per tutti i moduli nella lista: $MODULES"
  for MODULE in $MODULES; do
    # Ottieni l'ultima versione per ogni modulo
    LATEST_INFO=$(aws s3 cp s3://$S3_BUCKET/$MODULE/latest.json - 2>/dev/null)
    if [[ $? -eq 0 ]]; then
        VERSION=$(echo $LATEST_INFO | jq -r '.latestVersion')
        echo "Ultima versione trovata per $MODULE: $VERSION"
        download_and_run "$MODULE" "$VERSION"
    else
        echo "Errore: impossibile recuperare la versione più recente per $MODULE. Il modulo verrà saltato."
    fi

  done
else
# Se viene specificato il nome del modulo, verifica che esista nella lista
  if ! module_exists "$MODULE_NAME"; then
    echo "Errore: Modulo '$MODULE_NAME' non presente nella lista dei moduli."
    exit 1
  fi

    # Se viene specificato il nome del modulo
    if [[ -z "$SPECIFIC_VERSION" ]]; then
        # ma non la versione usa last
      echo "Nessuna versione specifica fornita per $MODULE_NAME, recupero l'ultima versione..."
      LATEST_INFO=$(aws s3 cp s3://$S3_BUCKET/$MODULE_NAME/latest.json - 2>/dev/null)

      if [[ $? -ne 0 ]]; then
        echo "Errore: Impossibile trovare informazioni sull'ultima versione per il modulo $MODULE_NAME"
        exit 1
      fi

      VERSION=$(echo $LATEST_INFO | jq -r '.latestVersion')
      echo "Ultima versione trovata: $VERSION"
    else
        # altrimenti usa quella specificata
      VERSION=$SPECIFIC_VERSION
      echo "Usando la versione specificata: $VERSION"
    fi
    download_and_run "$MODULE_NAME" "$VERSION"

fi