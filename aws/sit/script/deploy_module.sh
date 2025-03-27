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

# Creiamo la directory necessaria se non esiste
mkdir -p ${BASE_PATH}/aws/sit

# Assicura che la rete Docker esista
docker network create auxdromos-network 2>/dev/null || true

# Carica le variabili da BASE_DIR/env/deploy.env
if [[ -f "$BASE_DIR/env/deploy.env" ]]; then
  source "$BASE_DIR/env/deploy.env"
else
  echo "Errore: File deploy.env non trovato in $BASE_DIR/env"
  exit 1
fi

# Impostazione dei valori di default per i moduli se non presenti in deploy.env
MODULES=${MODULES:-"rdbms config gateway backend idp"}
MODULE_ORDER=${MODULE_ORDER:-"config rdbms idp backend gateway"}

# Recupera il nome del modulo passato come primo argomento
MODULO=$1

if [[ -z "$MODULO" ]]; then
  echo "Errore: nessun modulo specificato. Specificare un modulo o 'all' per deployare tutto."
  echo "Moduli disponibili: $MODULES"
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
  local REPOSITORY_NO_PREFIX="${MODULE_NAME}"

  echo "Ricerca dell'ultima immagine per ${MODULE_NAME} su ECR..."

  # Prima prova con il prefisso auxdromos (come fa la pipeline)
  if aws ecr describe-repositories --repository-names "$REPOSITORY" &>/dev/null; then
    # Ottieni l'ultimo tag dall'output di describe-images (ordinato per data di push)
    LATEST_TAG=$(aws ecr describe-images --repository-name "$REPOSITORY" --query 'sort_by(imageDetails, &imagePushedAt)[-1].imageTags[0]' --output text)

    if [[ -z "$LATEST_TAG" ]]; then
        echo "Nessun tag trovato per $REPOSITORY. Impossibile determinare l'ultima versione"
        export ECR_REPOSITORY_NAME="$REPOSITORY"
        return 1
    fi

    echo "Ultimo tag trovato: $LATEST_TAG"
    VERSION="$LATEST_TAG" # Imposta la variabile VERSION all'ultimo tag
    export ECR_REPOSITORY_NAME="$REPOSITORY"
    export VERSION # Esporta la variabile VERSION
    return 0
  fi

  # Se non trova con prefisso, prova senza prefisso
  echo "Repository con prefisso non trovato, verifico $REPOSITORY_NO_PREFIX..."
  if aws ecr describe-repositories --repository-names "$REPOSITORY_NO_PREFIX" &>/dev/null; then
    # Ottieni l'ultimo tag dall'output di describe-images (ordinato per data di push)
    LATEST_TAG=$(aws ecr describe-images --repository-name "$REPOSITORY_NO_PREFIX" --query 'sort_by(imageDetails, &imagePushedAt)[-1].imageTags[0]' --output text)

    if [[ -z "$LATEST_TAG" ]]; then
        echo "Nessun tag trovato per $REPOSITORY_NO_PREFIX. Impossibile determinare l'ultima versione"
        export ECR_REPOSITORY_NAME="$REPOSITORY_NO_PREFIX"
        return 1
    fi

    echo "Ultimo tag trovato: $LATEST_TAG"
    VERSION="$LATEST_TAG" # Imposta la variabile VERSION all'ultimo tag
    export ECR_REPOSITORY_NAME="$REPOSITORY_NO_PREFIX"
    export VERSION # Esporta la variabile VERSION
    return 0
  fi

  echo "Nessun repository trovato per il modulo $MODULE_NAME (cercato come $REPOSITORY e $REPOSITORY_NO_PREFIX)"

    # Per tutti i moduli, tenta di creare il repository con prefisso auxdromos-
    # perché è così che funziona la pipeline. Ritorna errore dato che l'immagine non esiste ancora.
    echo "Tentativo di creazione del repository $REPOSITORY..."
    if aws ecr create-repository --repository-name "$REPOSITORY" &>/dev/null; then
        echo "Repository $REPOSITORY creato con successo, ma non contiene ancora immagini."
        export ECR_REPOSITORY_NAME="$REPOSITORY"
        return 1
    else
        echo "Errore nella creazione del repository $REPOSITORY"
        return 1
    fi
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

  # Arresta e rimuovi i container esistenti, se presenti
  docker stop keycloak-db-auxdromos auxdromos-keycloak 2>/dev/null || true
  docker rm keycloak-db-auxdromos auxdromos-keycloak 2>/dev/null || true

  # Avvia il container del database PostgreSQL per Keycloak
  docker run -d \
    --name keycloak-db-auxdromos \
    --network auxdromos-network \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -v keycloak-data:/var/lib/postgresql/data \
    postgres:14

  # Attendi che il database sia pronto
  echo "Attendi che il database Keycloak sia pronto..."
  sleep 10

  # Avvia il container Keycloak
  docker run -d \
    --name auxdromos-keycloak \
    --network auxdromos-network \
    -p 8082:8080 \
    -e DB_VENDOR=postgres \
    -e DB_ADDR=keycloak-db-auxdromos \
    -e DB_DATABASE="${POSTGRES_DB}" \
    -e DB_USER="${POSTGRES_USER}" \
    -e DB_PASSWORD="${POSTGRES_PASSWORD}" \
    -e KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN}" \
    -e KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
    quay.io/keycloak/keycloak:26.0.7 start-dev

  # Verifica che Keycloak sia in esecuzione
  echo "Verifica che Keycloak sia in esecuzione..."
  for i in {1..12}; do
    if check_keycloak; then
      echo "✅ Keycloak è in esecuzione!"
      break
    fi
    echo "Attendi l'avvio di Keycloak... ($i/12)"
    sleep 10
    if [ $i -eq 12 ]; then
      echo "❌ Timeout durante l'avvio di Keycloak."
      exit 1
    fi
  done

  echo "Keycloak deployato con successo!"
}

# Funzione per deployare un modulo generico
deploy_module() {
  # Determina il percorso assoluto della cartella base (una directory sopra lo script)
  BASE_DIR="$(dirname "$(readlink -f "$0")")/.."

  # Carica le variabili da BASE_DIR/env/deploy.env
  if [[ -f "$BASE_DIR/env/deploy.env" ]]; then
    source "$BASE_DIR/env/deploy.env"
  else
    echo "Errore: File deploy.env non trovato in $BASE_DIR/env"
    exit 1
  fi

  # Impostazione dei valori di default per i moduli se non presenti in deploy.env
  MODULES=${MODULES:-"rdbms config gateway backend idp"}
  MODULE_ORDER=${MODULE_ORDER:-"config rdbms idp backend gateway"}

  # Recupera il nome del modulo passato come primo argomento
  MODULO=$1

  if [[ -z "$MODULO" ]]; then
    echo "Errore: nessun modulo specificato. Specificare un modulo o 'all' per deployare tutto."
    echo "Moduli disponibili: $MODULES"
    exit 1
  fi

  # Carica le variabili d'ambiente dal file .env del modulo.
  MODULE_ENV_FILE="$BASE_DIR/env/${MODULO}.env"
  if [[ -f "$MODULE_ENV_FILE" ]]; then
    source "$MODULE_ENV_FILE"
  else
    echo "Errore: File .env non trovato per il modulo $MODULO: $MODULE_ENV_FILE"
    exit 1
  fi

  echo "=== Inizio deploy di $MODULO $(date) ==="

  # Assicura che la variabile VERSION sia definita (esempio)
  VERSION=${VERSION:-"latest"}  # Imposta "latest" come predefinito se VERSION non è definita

  # Costruisci il nome dell'immagine
  REPOSITORY_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/auxdromos-${MODULO}:${VERSION}"

  IMAGE_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/auxdromos-${MODULO}:${VERSION}"
  CONTAINER_NAME="auxdromos-${MODULO}"

  # Esporta le variabili in modo che envsubst possa leggerle
  export IMAGE_NAME
  export CONTAINER_NAME
  # ... esporta altre variabili necessarie ...

  # Esegui la sostituzione delle variabili nel file docker-compose.yml
  envsubst < /app/distro/artifacts/aws/sit/docker/docker-compose.yml | /usr/local/bin/docker-compose -f - -p "${MODULO}" up -d "${MODULO}"
}

# Funzione per eseguire il deploy di tutti i moduli nell'ordine corretto
deploy_all() {
  # Successione predefinita dei moduli da deployare
  for module in $MODULE_ORDER; do
    echo "Deploying $module..."

    if [[ "$module" == "idp" ]]; then
      deploy_keycloak
    else
      deploy_module "$module"
    fi

    # Attendi tra i deploy per assicurarti che i servizi siano pronti
    sleep 5
  done
}

# Logica principale per scegliere cosa deployare
if [[ "$MODULO" == "all" ]]; then
  echo "Deploying all modules..."
  deploy_all
else
  # Verifica se il modulo specificato è valido
  if [[ " $MODULES " =~ " $MODULO " ]]; then
    if [[ "$MODULO" == "idp" ]]; then
      deploy_keycloak
    else
      deploy_module "$MODULO"
    fi
  else
    echo "Errore: modulo non valido. Moduli disponibili: $MODULES"
    exit 1
  fi
fi

echo "=== Deploy completato $(date) ==="