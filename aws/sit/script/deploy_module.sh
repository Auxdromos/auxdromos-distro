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

  echo "Verifico esistenza dell'immagine su ECR..."

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
    return 0
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
    echo "Attenzione: Nessuna immagine trovata per il modulo $MODULE_NAME su ECR e impossibile creare il repository. Il deployment sarà saltato."
    return 0
  fi

  # Recupera l'ultima versione stabile del modulo da ECR
  echo "Ricerca dell'ultima versione per il repository $ECR_REPOSITORY_NAME..."
  LATEST_VERSION=$(aws ecr describe-images --repository-name "$ECR_REPOSITORY_NAME" \
                   --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' --output text)

  if [[ "$LATEST_VERSION" == "None" || -z "$LATEST_VERSION" ]]; then
    echo "Attenzione: Nessuna versione trovata per il modulo $MODULE_NAME nel repository $ECR_REPOSITORY_NAME. Il deployment sarà saltato."
    return 0
  fi

  echo "Ultima versione trovata: $LATEST_VERSION"

  # Assicura che la rete esista
  docker network create auxdromos-network 2>/dev/null || true

  # Prepara l'URI completo dell'immagine
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}:${LATEST_VERSION}"

  echo "Utilizzo del repository ECR: $ECR_REPOSITORY_NAME"
  echo "Immagine completa: $IMAGE_URI"

  # Login al repository ECR
  aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

  # Pull dell'immagine da ECR
  echo "Pulling immagine $IMAGE_URI..."
  docker pull "$IMAGE_URI"

  # Determina il nome del container
  CONTAINER_NAME="auxdromos-${MODULE_NAME}"

  # Controlla se esiste già un container con questo nome e lo rimuove
  if docker ps -a | grep -q "$CONTAINER_NAME"; then
    echo "Rimozione del container esistente $CONTAINER_NAME..."
    docker rm -f "$CONTAINER_NAME"
  fi

  # Determina il file docker-compose da utilizzare (modulo specifico o generico)
  DOCKER_COMPOSE_FILE="$BASE_DIR/docker/docker-compose-${MODULE_NAME}.yml"
  if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
    echo "File docker-compose specifico per $MODULE_NAME non trovato, uso quello generico..."
    DOCKER_COMPOSE_FILE="$BASE_DIR/docker/docker-compose-module.yml"
  fi

  # Esporta variabili necessarie per docker-compose
  export MODULE_NAME
  export CONTAINER_NAME
  export IMAGE_URI

  # Deploy del modulo usando docker-compose
  echo "Deploying $MODULE_NAME usando $DOCKER_COMPOSE_FILE..."
  docker-compose -f "$DOCKER_COMPOSE_FILE" up -d

  # Verifica che il container sia partito
  if ! docker ps | grep -q "$CONTAINER_NAME"; then
    echo "ERRORE: Il container $CONTAINER_NAME non è stato avviato correttamente"
    docker logs "$CONTAINER_NAME"
    return 1
  fi

  echo "Deploy di $MODULE_NAME completato con successo!"
}

# Funzione per il deploy di tutti i moduli nell'ordine specificato
deploy_all() {
  echo "Deploying tutti i moduli nell'ordine: $MODULE_ORDER"

  # Deploy Keycloak prima di tutto se presente nella lista
  if [[ "$MODULE_ORDER" =~ "idp" || "$MODULES" =~ "idp" ]]; then
    deploy_keycloak
  fi

  # Deploy di ciascun modulo nell'ordine specificato
  for module in $MODULE_ORDER; do
    # Salta idp poiché è già gestito da deploy_keycloak
    if [[ "$module" != "idp" ]]; then
      echo "Deployando $module secondo l'ordine definito..."
      deploy_module "$module"
      # Aggiungi un piccolo ritardo tra i deployment
      sleep 5
    fi
  done

  # Verifica se ci sono moduli in MODULES che non sono in MODULE_ORDER
  for module in $MODULES; do
    if [[ ! "$MODULE_ORDER" =~ $module && "$module" != "idp" ]]; then
      echo "Deployando $module (non presente nell'ordine definito)..."
      deploy_module "$module"
      sleep 5
    fi
  done
}

# Funzione principale per eseguire il deployment
main() {
  # Assicurati che il login ECR sia valido
  echo "Login AWS ECR..."
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

  # Lista dei repository disponibili per controllo
  echo "Repository ECR disponibili:"
  aws ecr describe-repositories --query "repositories[].repositoryName" --output table

  if [[ "$MODULO" == "all" ]]; then
    deploy_all
  elif [[ "$MODULO" == "keycloak" || "$MODULO" == "idp" ]]; then
    deploy_keycloak
  else
    # Verifica se il modulo è nella lista dei moduli disponibili
    if [[ ! " $MODULES " =~ " $MODULO " ]]; then
      echo "ATTENZIONE: Il modulo $MODULO non è presente nella lista dei moduli configurati ($MODULES)."
      echo "Continuare comunque? (s/n)"
      read -r RISPOSTA
      if [[ "$RISPOSTA" != "s" && "$RISPOSTA" != "S" ]]; then
        echo "Operazione annullata."
        exit 0
      fi
    fi
    deploy_module "$MODULO"
  fi

  echo "=== Deploy completato con successo! ==="
}

# Mostra la lista dei moduli disponibili e l'ordine di deployment
echo "Moduli disponibili: $MODULES"
echo "Ordine di deployment: $MODULE_ORDER"

# Esecuzione della funzione principale
main