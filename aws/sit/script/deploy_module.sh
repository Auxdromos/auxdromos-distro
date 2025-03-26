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
MODULES=${MODULES:-"rdbms discovery config-server gateway backend idp"}
MODULE_ORDER=${MODULE_ORDER:-"discovery config-server gateway rdbms backend idp"}

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

  echo "Verifico esistenza dell'immagine ${MODULE_NAME} su ECR..."

  # Prima prova con il prefisso auxdromos (come fa la pipeline)
  if aws ecr describe-repositories --repository-names "$REPOSITORY" &>/dev/null; then
    # Verifica se ci sono immagini nel repository
    local IMAGE_COUNT
    IMAGE_COUNT=$(aws ecr describe-images --repository-name "$REPOSITORY" --query "length(imageDetails)" --output text)

    if [ "$IMAGE_COUNT" -eq "0" ]; then
      echo "Repository $REPOSITORY esiste ma non contiene immagini"
      export ECR_REPOSITORY_NAME="$REPOSITORY"
      return 1
    fi

    echo "Repository $REPOSITORY trovato con $IMAGE_COUNT immagini"
    export ECR_REPOSITORY_NAME="$REPOSITORY"
    return 0
  fi

  # Se non trova con prefisso, prova senza prefisso
  echo "Repository con prefisso non trovato, verifico $REPOSITORY_NO_PREFIX..."
  if aws ecr describe-repositories --repository-names "$REPOSITORY_NO_PREFIX" &>/dev/null; then
    # Verifica se ci sono immagini nel repository
    local IMAGE_COUNT
    IMAGE_COUNT=$(aws ecr describe-images --repository-name "$REPOSITORY_NO_PREFIX" --query "length(imageDetails)" --output text)

    if [ "$IMAGE_COUNT" -eq "0" ]; then
      echo "Repository $REPOSITORY_NO_PREFIX esiste ma non contiene immagini"
      export ECR_REPOSITORY_NAME="$REPOSITORY_NO_PREFIX"
      return 1
    fi

    echo "Repository $REPOSITORY_NO_PREFIX trovato con $IMAGE_COUNT immagini"
    export ECR_REPOSITORY_NAME="$REPOSITORY_NO_PREFIX"
    return 0
  fi

  echo "Nessun repository trovato per il modulo $MODULE_NAME (cercato come $REPOSITORY e $REPOSITORY_NO_PREFIX)"

  # Per tutti i moduli, tenta di creare il repository con prefisso auxdromos-
  # perché è così che funziona la pipeline
  echo "Tentativo di creazione del repository $REPOSITORY..."
  if aws ecr create-repository --repository-name "$REPOSITORY" &>/dev/null; then
    echo "Repository $REPOSITORY creato con successo"
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
  local MODULE_NAME=$1
  echo "===== Deploying ${MODULE_NAME}... ====="

  # Debug: verifichiamo il repository
  echo "DEBUG: Verificando repository auxdromos-${MODULE_NAME}"
  echo "DEBUG: AWS_DEFAULT_REGION=${AWS_DEFAULT_REGION}"
  echo "DEBUG: Elenco di tutti i repository:"
  aws ecr describe-repositories

  echo "DEBUG: Tentativo esplicito di trovare auxdromos-${MODULE_NAME}:"
  aws ecr describe-repositories --repository-names "auxdromos-${MODULE_NAME}" || true

  # Verifica se l'immagine esiste su ECR
  if ! check_image_exists "${MODULE_NAME}"; then
    echo "⚠️ Nessuna immagine trovata per ${MODULE_NAME}. Il deploy verrà saltato."
    return 1
  fi

  echo "Immagini trovate nel repository ${ECR_REPOSITORY_NAME}"

  # Ottieni la versione più recente dal repository ECR
  LATEST_VERSION=$(aws ecr describe-images --repository-name "${ECR_REPOSITORY_NAME}" \
    --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)

  # Se il risultato è "None" o vuoto, imposta una versione di default o interrompi
  if [[ "$LATEST_VERSION" == "None" || -z "$LATEST_VERSION" ]]; then
    echo "⚠️ Nessun tag trovato per l'immagine più recente. Utilizzo 'latest'."
    LATEST_VERSION="latest"
  fi

  echo "Ultima versione per ${MODULE_NAME} è ${LATEST_VERSION}"

  # Connettersi al repository ECR - usa AWS_ACCOUNT_ID o estrai dall'URI repository
  if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    # Estrai l'ID account dall'URI del repository
    REPO_INFO=$(aws ecr describe-repositories --repository-names "${ECR_REPOSITORY_NAME}" --query 'repositories[0].repositoryUri' --output text)
    AWS_ACCOUNT_ID=$(echo $REPO_INFO | cut -d'.' -f1)
  fi

  echo "Autenticazione al repository ECR..."
  aws ecr get-login-password | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

  # Pull dell'immagine
  REPOSITORY_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}:${LATEST_VERSION}"
  echo "Pull dell'immagine ${REPOSITORY_URI}"
  docker pull "${REPOSITORY_URI}"

  # Stoppa e rimuovi il container esistente se presente
  CONTAINER_NAME="auxdromos-${MODULE_NAME}"
  if docker ps -a | grep -q "${CONTAINER_NAME}"; then
    echo "Stopping e rimuovendo container esistente ${CONTAINER_NAME}..."
    docker stop "${CONTAINER_NAME}" || true
    docker rm "${CONTAINER_NAME}" || true
  fi

  # Determina le porte e le variabili d'ambiente specifiche per ogni modulo
  case "${MODULE_NAME}" in
    discovery)
      PORT="8761"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit"
      ;;
    config-server)
      PORT="8888"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://auxdromos-discovery:8761/eureka/"
      ;;
    gateway)
      PORT="8080"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://auxdromos-discovery:8761/eureka/"
      ;;
    rdbms)
      PORT="8090"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://auxdromos-discovery:8761/eureka/"
      ;;
    backend)
      PORT="8091"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://auxdromos-discovery:8761/eureka/"
      ;;
    idp)
      PORT="8092"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://auxdromos-discovery:8761/eureka/"
      ;;
    *)
      PORT="8080"
      ENV_VARS="-e SPRING_PROFILES_ACTIVE=sit -e EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://auxdromos-discovery:8761/eureka/"
      ;;
  esac

  # Aggiungi variabili d'ambiente da AWS se disponibili
  if [[ ! -z "$AWS_ACCESS_KEY_ID" && ! -z "$AWS_SECRET_ACCESS_KEY" ]]; then
    ENV_VARS="$ENV_VARS -e AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION"
  fi

  # Se si tratta del backend, aggiungi le variabili per il database se non è rdbms
  if [[ "${MODULE_NAME}" == "backend" && ! -z "$DB_HOST" ]]; then
    ENV_VARS="$ENV_VARS -e SPRING_DATASOURCE_URL=jdbc:postgresql://${DB_HOST}:5432/auxdromos?currentSchema=auxdromos&options=-c%20search_path%3Dauxdromos"
    ENV_VARS="$ENV_VARS -e SPRING_DATASOURCE_USERNAME=${DB_USER:-postgres}"
    ENV_VARS="$ENV_VARS -e SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD:-BbzcaI5HKm5wr3}"
  fi

  # Avvia il nuovo container
  echo "Avvio container ${CONTAINER_NAME} con porta ${PORT}..."
  docker run -d \
    --name "${CONTAINER_NAME}" \
    --network auxdromos-network \
    -p "${PORT}:${PORT}" \
    ${ENV_VARS} \
    "${REPOSITORY_URI}"

  # Verifica che il container sia stato avviato
  if docker ps | grep -q "${CONTAINER_NAME}"; then
    echo "✅ Container ${CONTAINER_NAME} avviato con successo!"
  else
    echo "❌ Errore nell'avvio del container ${CONTAINER_NAME}!"
    docker logs "${CONTAINER_NAME}"
    return 1
  fi

  # Mostra i primi log del container
  echo "Mostrando i primi log del container..."
  sleep 5  # Attendi che l'applicazione abbia avviato
  docker logs "${CONTAINER_NAME}"

  echo "Deploy del modulo ${MODULE_NAME} completato!"
  return 0
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