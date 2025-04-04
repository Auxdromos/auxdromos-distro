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
#!/bin/bash
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

  # --- SEZIONE GESTIONE MODULO CONFIG (invariata) ---
  if [[ "$MODULO" != "config" ]]; then
    if ! docker ps --format '{{.Names}}' | grep -q "^auxdromos-config$"; then # Controllo più preciso del nome container
      echo "Modulo 'config' non avviato. Avvio in corso..."
      deploy_module "config" # Chiamata ricorsiva
      local config_start_status=$?
      if [ $config_start_status -ne 0 ]; then
         echo "Errore: Fallito l'avvio del modulo 'config'. Deploy di $MODULO interrotto."
         exit 1
      fi
      if ! docker ps --format '{{.Names}}' | grep -q "^auxdromos-config$"; then
        echo "Errore: Impossibile avviare il modulo 'config' anche dopo il tentativo. Deploy di $MODULO interrotto."
        exit 1
      fi
      echo "Attendi 15 secondi per l'inizializzazione di config..."
      sleep 15
      echo "=== Prime righe di log del servizio config ==="
      docker logs --tail 20 auxdromos-config # Corretto typo auxdromos-congig -> auxdromos-config
      echo "=========================================="
      echo "=== Deploy di config completato con successo $(date) ==="
    fi
  fi
  # --- FINE SEZIONE GESTIONE MODULO CONFIG ---


  # --- NUOVA SEZIONE: TROVA L'ULTIMO TAG DA ECR ---
  local REPO_NAME="auxdromos-${MODULO}" # Costruisce il nome del repository ECR
  local FULL_REPO_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"

  echo "Recupero dell'ultimo tag per il repository ECR: ${REPO_NAME}..."

  # Interroga ECR per le immagini, ordinate per data di push (default), prendi l'ultima (-1) e il suo primo tag ([0])
  # NOTA: Assicurati che AWS CLI v2 sia installata e funzionante
  LATEST_TAG=$(aws ecr describe-images \
                --repository-name "${REPO_NAME}" \
                --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags[0]' \
                --output text \
                --region "${AWS_DEFAULT_REGION}" 2>/dev/null) # Redirige stderr per non sporcare l'output in caso di errori "minori" come repo vuoto

  # Verifica se il comando ha avuto successo e se il tag è stato trovato
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
      exit 1
  fi

  # Costruisci il nome completo dell'immagine con il tag trovato
  local IMAGE_NAME="${FULL_REPO_BASE}/${REPO_NAME}:${LATEST_TAG}"
  echo "Utilizzo l'immagine trovata: $IMAGE_NAME"
  # --- FINE NUOVA SEZIONE ---


  # Rinnova l'autenticazione AWS ECR (invariato)
  echo "Rinnovamento autenticazione AWS ECR..."
  aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${FULL_REPO_BASE}
  if [ $? -ne 0 ]; then
      echo "Errore durante l'autenticazione a AWS ECR."
      # ... (gestione errore autenticazione come prima) ...
      exit 1
  fi

  # --- MODIFICA: USA UN FILE COMPOSE TEMPORANEO ---
  # Crea un file compose temporaneo per evitare di modificare l'originale
  local TEMP_COMPOSE_FILE=$(mktemp)
  # Assicurati che il file temporaneo venga eliminato all'uscita dallo script
  trap 'rm -f "$TEMP_COMPOSE_FILE"' EXIT SIGINT SIGTERM

  cp "${COMPOSE_FILE_ORIGINAL}" "${TEMP_COMPOSE_FILE}"

  # Definisci il placeholder ESATTO da sostituire (con :latest e variabili espanse se necessario)
  # NOTA: Assumiamo che il compose file originale usi :latest
  local PLACEHOLDER_IMAGE="${FULL_REPO_BASE}/${REPO_NAME}:latest"

  # Modifica il file compose TEMPORANEO per usare l'immagine specifica
  # Usiamo '|' come delimitatore per sed per evitare conflitti con '/' nei nomi immagine
  sed -i "s|image: ${PLACEHOLDER_IMAGE}|image: ${IMAGE_NAME}|" "${TEMP_COMPOSE_FILE}"
  if [ $? -ne 0 ]; then
      echo "Errore: Impossibile modificare il file compose temporaneo con sed."
      exit 1
  fi
  # --- FINE MODIFICA ---

  # Vai alla directory docker ed esegui docker-compose con i file ENV appropriati
  cd "$BASE_DIR/docker"

  # Stop e rimuovi il container se esiste (invariato)
  # Usare il nome container definito nel compose file se diverso da auxdromos-${MODULO}
  local CONTAINER_NAME="auxdromos-${MODULO}" # Assicurati sia il nome corretto
  echo "Stop e rimozione container esistente ${CONTAINER_NAME}..."
  docker stop ${CONTAINER_NAME} >/dev/null 2>&1 || true
  docker rm ${CONTAINER_NAME} >/dev/null 2>&1 || true

  # Rimuovi l'immagine vecchia localmente per forzare il pull della nuova (opzionale ma consigliato)
  echo "Rimozione immagine locale precedente (se esiste) per forzare il pull..."
  docker image rm ${PLACEHOLDER_IMAGE} >/dev/null 2>&1 || true # Rimuove l'eventuale immagine :latest locale
  docker image rm $(docker images -q ${FULL_REPO_BASE}/${REPO_NAME} | grep -v ${LATEST_TAG}) >/dev/null 2>&1 || true # Rimuove vecchie versioni locali

  # Ottieni il nome della directory che contiene il docker-compose.yml originale
  local COMPOSE_DIR=$(dirname "${COMPOSE_FILE_ORIGINAL}")
  # Usa il nome della directory come nome del progetto
  local PROJECT_NAME=$(basename "${COMPOSE_DIR}")
  echo "Utilizzo il nome progetto Docker Compose: ${PROJECT_NAME}"

  echo "Avvio container ${CONTAINER_NAME} con docker-compose..."
  # Esegui docker-compose per il modulo specifico usando il file TEMPORANEO
  docker-compose -p "${PROJECT_NAME}" \
                 --file "${TEMP_COMPOSE_FILE}" \
                 --env-file "$BASE_DIR/env/${MODULO}.env" \
                 --env-file "$BASE_DIR/env/deploy.env" \
                 up -d $MODULO

  # Verifica se il container è stato avviato correttamente (invariato)
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      echo "Container ${CONTAINER_NAME} avviato con successo."
      # ... (attesa e stampa log come prima) ...
      echo "Attendi 10 secondi per l'inizializzazione..."
      sleep 10
      echo "=== Prime righe di log del servizio ${MODULO} ==="
      docker logs --tail 20 ${CONTAINER_NAME}
      echo "=========================================="
      echo "=== Deploy di $MODULO (tag: ${LATEST_TAG}) completato con successo $(date) ==="
  else
      echo "Errore nell'avvio del container ${CONTAINER_NAME}."
      echo "=== Deploy di $MODULO (tag: ${LATEST_TAG}) fallito $(date) ==="
      # ... (stampa log errore come prima) ...
      echo "Ultime righe di log del container (se disponibili):"
      docker logs --tail 50 ${CONTAINER_NAME} 2>/dev/null || echo "Nessun log disponibile"
      exit 1
  fi

  # Il trap pulirà automaticamente il file temporaneo all'uscita
}

# Funzione per eseguire il deploy di tutti i moduli nell'ordine corretto
deploy_all() {
  # Successione predefinita dei moduli da deployare
  for module in $MODULE_ORDER; do
    echo "Deploying $module..."

    deploy_module "$module"

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
