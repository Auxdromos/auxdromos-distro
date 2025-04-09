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

# Assicura che la rete Docker esista
docker network create auxdromos-network 2>/dev/null || true

# Recupera il nome del modulo passato come primo argomento
MODULO=$1

# Impostazione dei valori di default per i moduli se non presenti in deploy.env
MODULES=${MODULES:-"config rdbms keycloak gateway backend idp"}
MODULE_ORDER=${MODULE_ORDER:-"config rdbms keycloak idp backend gateway"}


if [[ -z "$MODULO" ]]; then
  echo "Errore: nessun modulo specificato. Specificare un modulo o 'all' per deployare tutto."
  echo "Moduli disponibili: $MODULES"
  exit 1
fi

echo "=== Inizio deploy di $MODULO $(date) ==="

# Carica le variabili specifiche del modulo *DOPO* aver ottenuto il nome del modulo
if [[ -f "$BASE_DIR/env/${MODULO}.env" ]]; then
  source "$BASE_DIR/env/${MODULO}.env"
else
  echo "Errore: File ${MODULO}.env non trovato in $BASE_DIR/env"
  exit 1
fi


# Funzione per verificare se Keycloak è in esecuzione
check_keycloak() {
  # Verifica se il container è in esecuzione
  if ! docker ps | grep -q "auxdromos-keycloak"; then
    # Controlla se il container è terminato con errore
    if docker ps -a | grep "auxdromos-keycloak" | grep -q "Exited"; then
      echo "⚠️ Container Keycloak avviato ma terminato con errore. Log degli ultimi 50 righe:"
      docker logs auxdromos-keycloak --tail 50
      return 2  # Codice di errore specifico per container terminato
    fi
    return 1  # Container non trovato
  fi

  # Verifica che Keycloak sia realmente pronto rispondendo a una richiesta HTTP
  if curl --silent --fail --max-time 5 http://localhost:8082/health > /dev/null 2>&1 ||
     curl --silent --fail --max-time 5 http://localhost:8082/auth > /dev/null 2>&1 ||
     curl --silent --fail --max-time 5 http://localhost:8082/realms/master > /dev/null 2>&1; then
    return 0  # Keycloak è pronto e risponde
  else
    return 1  # Keycloak è in esecuzione ma non risponde
  fi
}

# Funzione per verificare se un'immagine esiste su ECR
check_image_exists() {
  local MODULE_NAME=$1
  local REPOSITORY="auxdromos-${MODULE_NAME}"
  local REPOSITORY_NO_PREFIX="${MODULE_NAME}"

  echo "Ricerca dell'ultima immagine per ${MODULE_NAME} su ECR..."

  # Ottieni il token di autenticazione per ECR
  aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com

  if [ $? -ne 0 ]; then
      echo "Errore di autenticazione con ECR. Verificare le credenziali AWS."
      return 1
  fi

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

        export AWS_ACCOUNT_ID AWS_DEFAULT_REGION VERSION ECR_REPOSITORY_NAME # Esporta le variabili
        return 0
}

# Funzione per effettuare il deploy di Keycloak e il setup
deploy_keycloak() {
  echo "===== Deploying Keycloak... ====="
  local BASE_DIR="$(dirname "$(readlink -f "$0")")/.."
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

echo "KC_DB_URL: $KC_DB_URL"
echo "KEYCLOAK_ADMIN: $KEYCLOAK_ADMIN"
# Attenzione: mostrare la password in chiaro può rappresentare un rischio di sicurezza
echo "KEYCLOAK_ADMIN_PASSWORD: $KEYCLOAK_ADMIN_PASSWORD"

  docker run -d \
    --name auxdromos-keycloak \
    --network auxdromos-network \
    -p 8082:8080 \
    -e KC_DB=postgres \
    -e KC_DB_URL="${KC_DB_URL}" \
    -e KC_HOSTNAME=localhost \
    -e KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN}" \
    -e KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD}" \
    quay.io/keycloak/keycloak:26.0.7 start-dev
  # Verifica che Keycloak sia in esecuzione
  echo "Verifica che Keycloak sia in esecuzione..."
for i in {1..12}; do
  STATUS=$(check_keycloak)
  EXIT_CODE=$?

  if [ $EXIT_CODE -eq 0 ]; then
    echo "✅ Keycloak è in esecuzione e risponde alle richieste!"
    break
  elif [ $EXIT_CODE -eq 2 ]; then
    echo "❌ Container Keycloak terminato con errore. Interrompo il deploy."
    exit 1
  fi

  echo "Attendi l'avvio di Keycloak... ($i/12)"

  # Ogni 3 tentativi, mostra alcuni log per aiutare il debug
  if [ $((i % 3)) -eq 0 ]; then
    echo "📋 Log recenti di Keycloak:"
    docker logs auxdromos-keycloak --tail 20 2>/dev/null || echo "Nessun log disponibile"
  fi

  sleep 10
  if [ $i -eq 12 ]; then
    echo "❌ Timeout durante l'avvio di Keycloak."
    echo "📋 Mostro gli ultimi 50 log per debug:"
    docker logs auxdromos-keycloak --tail 50 2>/dev/null || echo "Nessun log disponibile"
    exit 1
  fi
done

  echo "Keycloak deployato con successo!"
}

# Funzione per deployare un modulo generico
deploy_module() {
  # Determina il percorso assoluto della cartella base (una directory sopra lo script)
  local BASE_DIR="$(dirname "$(readlink -f "$0")")/.."
  local MODULO="$1"
  local COMPOSE_FILE_ORIGINAL="$BASE_DIR/docker/docker-compose.yml"

  # Carica le variabili GLOBALI da BASE_DIR/env/deploy.env (necessarie per AWS creds, region, account etc.)
  if [[ -f "$BASE_DIR/env/deploy.env" ]]; then
    source "$BASE_DIR/env/deploy.env"
  else
    echo "Errore: File deploy.env non trovato in $BASE_DIR/env"
    exit 1
  fi

  # Verifica la presenza delle variabili AWS essenziali
  if [[ -z "$AWS_ACCOUNT_ID" || -z "$AWS_DEFAULT_REGION" ]]; then
    echo "Errore: AWS_ACCOUNT_ID o AWS_DEFAULT_REGION non sono definite in deploy.env"
    exit 1
  fi

  # --- TROVA L'ULTIMO TAG DA ECR ---
  local REPO_NAME="auxdromos-${MODULO}" # Costruisce il nome del repository ECR
  local FULL_REPO_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

  echo "Recupero dell'ultimo tag per il repository ECR: ${REPO_NAME}..."

  LATEST_TAG=$(aws ecr describe-images \
                --repository-name "${REPO_NAME}" \
                --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' \
                --output text \
                --region "${AWS_DEFAULT_REGION}" 2>/dev/null)

  if [ $? -ne 0 ] || [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" == "None" ]; then
      echo "Errore: Impossibile trovare l'ultimo tag per il repository ${REPO_NAME} in ECR."
      echo "Possibili cause: Repository non esiste, nessun'immagine pushata, errore AWS CLI o permessi insufficienti."
      # Verifica dettagli ruolo IAM dell'istanza (può aiutare nel debug dei permessi)
      echo "Verifica ruolo IAM dell'istanza (se applicabile):"
      TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
      if [ -n "$TOKEN" ]; then
          ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null)
          echo "Ruolo/Credenziali rilevato: $ROLE"
          echo "Verificare che il ruolo/utente abbia i permessi ecr:DescribeImages."
      else
          echo "Impossibile recuperare metadati EC2 (potrebbe non essere un'istanza EC2)."
      fi
      exit 1 # Esce se non trova il tag
  fi

  local IMAGE_NAME_WITH_TAG="${FULL_REPO_BASE}/${REPO_NAME}:${LATEST_TAG}"
  echo "Utilizzo l'immagine trovata: $IMAGE_NAME_WITH_TAG"
  # --- FINE TROVA TAG ---


  # Rinnova l'autenticazione AWS ECR
  echo "Rinnovamento autenticazione AWS ECR..."
  aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${FULL_REPO_BASE}
  if [ $? -ne 0 ]; then
      echo "Errore durante l'autenticazione a AWS ECR."
      exit 1
  fi
  echo "Login Succeeded" # Aggiunto per coerenza con il log precedente


  # --- RIMOSSA LA SEZIONE DI MODIFICA DEL FILE COMPOSE CON SED ---


  # --- ESPORTA LA VARIABILE D'AMBIENTE PER IL TAG ---
  # Crea il nome della variabile dinamicamente (es. RDBMS_IMAGE_TAG)
  typeset -u upper_modulo="${MODULO}" # Rende il nome del modulo maiuscolo (bash/ksh/zsh)
  # Alternativa POSIX: upper_modulo=$(echo "$MODULO" | tr '[:lower:]' '[:upper:]')
  local DOCKER_TAG_VAR="${upper_modulo}_IMAGE_TAG"
  export ${DOCKER_TAG_VAR}="${LATEST_TAG}"
  echo "Esportata variabile d'ambiente: ${DOCKER_TAG_VAR}=${LATEST_TAG}" # Verifica

  # Vai alla directory docker
  cd "$BASE_DIR/docker"

  # Ottieni il nome della directory che contiene il docker-compose.yml originale
  local COMPOSE_DIR=$(dirname "${COMPOSE_FILE_ORIGINAL}")
  # Usa il nome della directory come nome del progetto
  local PROJECT_NAME=$(basename "${COMPOSE_DIR}")
  echo "Utilizzo il nome progetto Docker Compose: ${PROJECT_NAME}"

  # Stop e rimuovi il container se esiste
  local CONTAINER_NAME="auxdromos-${MODULO}" # Assicurati sia il nome corretto
  echo "Stop e rimozione container esistente ${CONTAINER_NAME}..."
  # Usa il file compose originale per stop e rm
  docker-compose -p "${PROJECT_NAME}" --file "${COMPOSE_FILE_ORIGINAL}" stop $MODULO >/dev/null 2>&1 || echo "Container $MODULO non in esecuzione o già fermato."
  docker-compose -p "${PROJECT_NAME}" --file "${COMPOSE_FILE_ORIGINAL}" rm -f $MODULO >/dev/null 2>&1 || echo "Container $MODULO non trovato per la rimozione."

  # Rimuovi l'immagine vecchia localmente per forzare il pull della nuova
  echo "Rimozione immagine locale precedente (se esiste) per forzare il pull..."
  # Rimuove l'immagine specifica con il tag trovato
  docker image rm ${IMAGE_NAME_WITH_TAG} >/dev/null 2>&1 || echo "Immagine locale ${IMAGE_NAME_WITH_TAG} non trovata o già rimossa."
  # Rimuove anche l'eventuale immagine :latest locale per sicurezza
  docker image rm ${FULL_REPO_BASE}/${REPO_NAME}:latest >/dev/null 2>&1 || true


  echo "Avvio container ${CONTAINER_NAME} con docker-compose..."
  # Esegui docker-compose per il modulo specifico usando il file ORIGINALE
  # Docker Compose userutomaticamente la variabile d'ambiente esportata (es. RDBMS_IMAGE_TAG)
  docker-compose -p "${PROJECT_NAME}" \
                 --file "${COMPOSE_FILE_ORIGINAL}" \
                 --env-file "$BASE_DIR/env/${MODULO}.env" \
                 --env-file "$BASE_DIR/env/deploy.env" \
                 up -d $MODULO

  # Verifica se il container è stato avviato correttamente
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      echo "Container ${CONTAINER_NAME} avviato con successo."
      echo "Attendi 10 secondi per l'inizializzazione..."
      sleep 10
      echo "=== Prime righe di log del servizio ${MODULO} ==="
      docker logs --tail 20 ${CONTAINER_NAME}
      echo "=========================================="
      echo "=== Deploy di $MODULO (tag: ${LATEST_TAG}) completato con successo $(date) ==="
      # Non usare exit 0 qui se questa funzione è chiamata da deploy_all
      return 0
  else
      echo "Errore nell'avvio del container ${CONTAINER_NAME}."
      echo "=== Deploy di $MODULO (tag: ${LATEST_TAG}) fallito $(date) ==="
      echo "Ultime righe di log del container (se disponibili):"
      docker logs --tail 50 ${CONTAINER_NAME} 2>/dev/null || echo "Nessun log disponibile"
      # Non usare exit 1 qui se questa funzione è chiamata da deploy_all
      return 1 # Ritorna un codice di errore per indicare fallimento
  fi
}

# Funzione per eseguire il deploy di tutti i moduli nell'ordine corretto
deploy_all() {
  # Successione predefinita dei moduli da deployare
  for module in $MODULE_ORDER; do
    echo "Deploying $module..."

    deploy_module "$module"

    # Attendi tra i deploy per assicurarti che i servizi siano pronti
    sleep 15
  done
}

# Logica principale per scegliere cosa deployare
if [[ "$MODULO" == "all" ]]; then
  echo "Deploying all modules..."
  deploy_all
else
  # Verifica se il modulo specificato è valido
  if [[ " $MODULES " =~ " $MODULO " ]]; then
#    if [[ "$MODULO" == "keycloak" ]]; then
#      deploy_keycloak
#    else
#      deploy_module "$MODULO"
#    fi
    deploy_module "$MODULO"

  else
    echo "Errore: modulo non valido. Moduli disponibili: $MODULES"
    exit 1
  fi
fi

echo "=== Deploy completato $(date) ==="
