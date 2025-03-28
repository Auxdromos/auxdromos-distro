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
MODULES=${MODULES:-"rdbms config gateway backend idp"}
MODULE_ORDER=${MODULE_ORDER:-"config rdbms idp backend gateway"}


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
  docker ps | grep -q "keycloak-auxdromos"
  return $?
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
#!/bin/bash
deploy_module() {
  # Determina il percorso assoluto della cartella base (una directory sopra lo script)
  local BASE_DIR="$(dirname "$(readlink -f "$0")")/.."
  local MODULO="$1"


  # Carica le variabili GLOBALI da BASE_DIR/env/deploy.env (una sola volta)
  if [[ -f "$BASE_DIR/env/deploy.env" ]]; then
    source "$BASE_DIR/env/deploy.env"
  else
    echo "Errore: File deploy.env non trovato in $BASE_DIR/env"
    exit 1
  fi

  # Nel deploy_module.sh
  if check_image_exists "$MODULO"; then
      IMAGE_NAME="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}:${VERSION}"
      echo "Utilizzo l'immagine: $IMAGE_NAME"

      # Rinnova l'autenticazione AWS ECR
      echo "Rinnovamento autenticazione AWS ECR..."
      aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com

      if [ $? -ne 0 ]; then
          echo "Errore durante l'autenticazione a AWS ECR."
          # Verifica dettagli ruolo IAM dell'istanza
          echo "Dettagli ruolo IAM dell'istanza:"
          TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
          ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/)
          echo "Ruolo dell'istanza: $ROLE"

          # Verifica policy associate al ruolo
          echo "Per favore, verificare che al ruolo dell'istanza siano associate le policy ECR necessarie:"
          echo "- AmazonECR-FullAccess o policy personalizzata con i permessi ECR"
          exit 1
      fi

      # Modifica il docker-compose.yml per usare l'immagine specifica invece di latest
      sed -i "s@image: \${AWS_ACCOUNT_ID}.dkr.ecr.\${AWS_DEFAULT_REGION}.amazonaws.com/auxdromos-${MODULO}:latest@image: ${IMAGE_NAME}@" "$BASE_DIR/docker/docker-compose.yml"

      # Vai alla directory docker ed esegui docker-compose con i file ENV appropriati
      cd "$BASE_DIR/docker"

      # Stop e rimuovi il container se esiste
      docker stop auxdromos-${MODULO} 2>/dev/null || true
      docker rm auxdromos-${MODULO} 2>/dev/null || true

      # Esegui docker-compose per il modulo specifico con i file ENV
      docker-compose --env-file "$BASE_DIR/env/${MODULO}.env" --env-file "$BASE_DIR/env/deploy.env" up -d $MODULO
  else
      echo "Immagine non trovata per $MODULO. Deploy fallito."
      exit 1
  fi
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
    if [[ "$MODULO" == "keycloak" ]]; then
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