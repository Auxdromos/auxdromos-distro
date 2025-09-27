#!/bin/bash
# Script per deployare moduli applicativi AuxDromos tramite Docker Compose
# Utilizza AWS Systems Manager Parameter Store per la configurazione e i segreti.

# Opzioni per uscire in caso di errore e gestire errori nelle pipe
set -eo pipefail

# Determine the absolute path of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Set BASE_DIR to two directories up from the script location
BASE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Path for AWS SSM Parameter Store parameters
GLOBAL_PARAM_PATH="/auxdromos/sit/global"
SCRIPT_PARAM_PATH="/auxdromos/sit/script"

# --- NUOVA FUNZIONE: Recupera ed esporta parametri da AWS SSM ---
# Richiede AWS CLI v2 e jq installati
fetch_and_export_params() {
  local PARAM_PATH="$1"
  local AWS_REGION_PARAM="$2" # Passa la regione come argomento
  local TEMP_ENV_FILE=$(mktemp)
  echo "Recupero parametri da AWS SSM Path: ${PARAM_PATH} nella regione ${AWS_REGION_PARAM}..."

  # Improved parameter fetching and export
  aws ssm get-parameters-by-path \
    --path "$PARAM_PATH" \
    --with-decryption \
    --recursive \
    --region "${AWS_REGION_PARAM}" \
    --output json | \
    jq -r '.Parameters[] | .Name + "=" + .Value' | \
    while IFS='=' read -r key value; do
      local param_name=$(basename "$key")
      echo "Esportazione parametro: ${param_name}"
      echo "export ${param_name}='${value}'" >> "$TEMP_ENV_FILE"
    done

  # Source the temporary file to set variables in current environment
  if [ -f "$TEMP_ENV_FILE" ] && [ -s "$TEMP_ENV_FILE" ]; then
    source "$TEMP_ENV_FILE"
    rm -f "$TEMP_ENV_FILE"
    echo "Parametri caricati nell'ambiente corrente."
  else
    echo "Attenzione: Nessun parametro trovato in ${PARAM_PATH}"
    rm -f "$TEMP_ENV_FILE"
    return 1
  fi

  # Verifica se la pipe ha avuto successo (jq o aws potrebbero fallire)
  local pipe_status=${PIPESTATUS[0]} # Controlla lo stato di uscita del comando aws ssm
  if [ $pipe_status -ne 0 ]; then
       echo "Errore: Il comando aws ssm get-parameters-by-path per ${PARAM_PATH} ha fallito con codice ${pipe_status}."
       return 1 # Ritorna errore
  fi

  # Verifica aggiuntiva: controlla se almeno una variabile attesa è stata esportata (opzionale)
  # Esempio: if [[ -z "${EXPECTED_VAR_FROM_THIS_PATH}" ]]; then echo "Warning: Expected var not found"; fi

  echo "Recupero parametri da ${PARAM_PATH} completato."
  return 0 # Successo
}
# --- FINE NUOVA FUNZIONE ---

# --- Funzioni Helper (Opzionali, da adattare se le usi) ---
# check_keycloak() { ... }
# check_image_exists() { ... }
# Assicurati che usino le variabili AWS_DEFAULT_REGION e AWS_ACCOUNT_ID dall'ambiente

# --- Funzione deploy_keycloak (Opzionale, se preferisci gestirlo separatamente da compose) ---
# Se decidi di usare questa funzione, adattala come nella risposta precedente
# per recuperare i parametri da SSM e usare `docker run` con le variabili -e.
# Altrimenti, se Keycloak è gestito solo da docker-compose.yml, puoi rimuovere questa funzione.

# --- Funzione deploy_module (per moduli gestiti da docker-compose.yml) ---
deploy_module() {
  local module_to_deploy="$1"
  # Determina il percorso del file docker-compose.yml
  local compose_file_path="$BASE_DIR/sit/docker/docker-compose.yml" # Adjusted to avoid duplicate aws/

  echo ""
  echo "-----------------------------------------"
  echo "Deploying $module_to_deploy..."
  echo "-----------------------------------------"

  # --- OTTIENI REGIONE AWS (Esempio: da metadati EC2) ---
  # Questo viene fatto una sola volta all'inizio dello script ora
  if [[ -z "$AWS_DEFAULT_REGION" ]]; then
      echo "Errore critico: AWS_DEFAULT_REGION non definita."
      return 1
  fi
  # --- FINE OTTIENI REGIONE ---

  # --- RECUPERA PARAMETRI GLOBALI, SCRIPT E MODULO DA SSM ---
  # I parametri globali e script sono già stati caricati da deploy_all o all'inizio
  # Carichiamo solo quelli specifici del modulo
  local MODULE_PARAM_PATH="/auxdromos/sit/${module_to_deploy}"

  echo "Recupero parametri specifici per il modulo ${module_to_deploy}..."
  if ! fetch_and_export_params "$MODULE_PARAM_PATH" "$AWS_DEFAULT_REGION"; then
      echo "Attenzione: Nessun parametro specifico trovato per il modulo ${module_to_deploy}."
      echo "Procedo con i parametri globali e di script già caricati."
  else
      echo "Parametri specifici per ${module_to_deploy} caricati con successo."
  fi
  # --- FINE RECUPERO PARAMETRI MODULO ---

  # Verifica variabili AWS essenziali (già caricate)
  if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    echo "Errore: AWS_ACCOUNT_ID non trovato nell'ambiente."
    return 1
  fi
  # Verifica altre variabili globali/script necessarie qui, se serve

  # --- TROVA L'ULTIMO TAG DA ECR ---
  if [[ "$module_to_deploy" != "keycloak" && "$module_to_deploy" != "config" ]]; then
    AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}
    REPO_NAME="auxdromos-${module_to_deploy}"
    FULL_REPO_BASE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com"
    echo "Recupero dell'ultimo tag per il repository ECR: ${REPO_NAME}..."
  fi
  # --- TROVA L'ULTIMO TAG DA ECR ---
  if [[ "$module_to_deploy" != "keycloak" && "$module_to_deploy" != "config" ]]; then
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    ENV_NAME="${ENV_NAME:-sit}"
    AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
    FULL_REPO_BASE="${FULL_REPO_BASE:-${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com}"
    REPO_NAME="auxdromos-${module_to_deploy}"

    echo "Recupero dell'ultimo tag per il repository ECR: ${REPO_NAME}..."

    LATEST_TAG=$(aws ecr describe-images \
      --repository-name "${REPO_NAME}" \
      --region "${AWS_DEFAULT_REGION}" \
      --filter tagStatus=TAGGED \
      --query 'reverse(sort_by(imageDetails,&imagePushedAt))[0].imageTags[0]' \
      --output text)

    if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "None" ]]; then
      echo "Tag ECR mancante. Fallback SSM..."
      LATEST_TAG=$(aws ssm get-parameter \
        --name "/auxdromos/${ENV_NAME}/${module_to_deploy}/IMAGE_TAG" \
        --region "${AWS_DEFAULT_REGION}" \
        --query 'Parameter.Value' --output text 2>/dev/null || true)
    fi

    if [[ -z "${LATEST_TAG}" || "${LATEST_TAG}" == "None" ]]; then
      echo "Errore: nessun tag valido per ${REPO_NAME} in ${AWS_DEFAULT_REGION}."; exit 1
    fi

    echo "Tag trovato: ${LATEST_TAG}"
    IMAGE_NAME_WITH_TAG="${FULL_REPO_BASE}/${REPO_NAME}:${LATEST_TAG}"

    upper_modulo="${module_to_deploy^^}"; upper_modulo="${upper_modulo//-/_}"
    DOCKER_TAG_VAR="${upper_modulo}_IMAGE_TAG"
    DOCKER_IMAGE_VAR="${upper_modulo}_IMAGE"

    export "${DOCKER_TAG_VAR}=${LATEST_TAG}"
    export "${DOCKER_IMAGE_VAR}=${IMAGE_NAME_WITH_TAG}"
    echo "Esportata variabile d'ambiente: ${DOCKER_TAG_VAR}=${LATEST_TAG}"
    echo "Esportata variabile d'ambiente: ${DOCKER_IMAGE_VAR}=${IMAGE_NAME_WITH_TAG}"

    echo "Rinnovamento autenticazione AWS ECR..."
    aws ecr get-login-password --region "${AWS_DEFAULT_REGION}" \
      | docker login --username AWS --password-stdin "${FULL_REPO_BASE}"
  else
    LATEST_TAG="N/A"
  fi
  # --- FINE LOGICA ECR ---

  # Vai alla directory del docker-compose
  local compose_dir=$(dirname "${compose_file_path}")
  cd "$compose_dir" || { echo "Errore: directory $compose_dir non trovata."; return 1; }

  # Ottieni il nome del progetto Docker Compose (nome della directory)
  local PROJECT_NAME=$(basename "${compose_dir}")
  echo "Utilizzo il nome progetto Docker Compose: ${PROJECT_NAME}"

  # Stop e rimuovi il container se esiste
  local CONTAINER_NAME="auxdromos-${module_to_deploy}"
  echo "Stop e rimozione container esistente ${CONTAINER_NAME}..."
  docker-compose -p "${PROJECT_NAME}" --file "${compose_file_path}" stop $module_to_deploy >/dev/null 2>&1 || echo "Info: Container $module_to_deploy non in esecuzione o già fermato."
  docker-compose -p "${PROJECT_NAME}" --file "${compose_file_path}" rm -f $module_to_deploy >/dev/null 2>&1 || echo "Info: Container $module_to_deploy non trovato per la rimozione."

  # Rimuovi l'immagine vecchia localmente (solo se abbiamo trovato un tag ECR)
  if [[ "$LATEST_TAG" != "N/A" ]]; then
      echo "Rimozione immagine locale precedente (se esiste) per forzare il pull..."
      docker image rm ${IMAGE_NAME_WITH_TAG} >/dev/null 2>&1 || echo "Info: Immagine locale ${IMAGE_NAME_WITH_TAG} non trovata o già rimossa."
      # Rimuovi anche il tag :latest se presente
      docker image rm ${FULL_REPO_BASE}/${REPO_NAME}:latest >/dev/null 2>&1 || true
  fi

  echo "Avvio container ${CONTAINER_NAME} con docker-compose..."
  # --- COMANDO DOCKER-COMPOSE MODIFICATO: SENZA --env-file ---
  # Usa le variabili esportate da fetch_and_export_params e quelle del tag
  if ! docker-compose -p "${PROJECT_NAME}" \
                 --file "${compose_file_path}" \
                 -f "docker-compose.override.yml" \
                 up -d $module_to_deploy; then
      echo "Errore durante l'esecuzione di 'docker-compose up' per ${module_to_deploy}."
      # Mostra log in caso di fallimento dell'up
      echo "Ultime righe di log del tentativo di avvio:"
      docker logs --tail 50 ${CONTAINER_NAME} 2>/dev/null || echo "Nessun log disponibile per ${CONTAINER_NAME}"
      return 1
  fi
  # --- FINE COMANDO ---

  echo "Verifica avvio container ${CONTAINER_NAME}..."
  sleep 5 # Breve attesa per dare tempo al container di apparire
  if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
      echo "Container ${CONTAINER_NAME} avviato con successo."
      echo "Attesa inizializzazione del modulo..."

      # Imposta un timeout di 60 secondi per l'inizializzazione
      local TIMEOUT=60
      local START_TIME=$(date +%s)
      local INITIALIZED=false

      # Controlla i log fino a quando non trova il messaggio di inizializzazione o scade il timeout
      while [ $(($(date +%s) - START_TIME)) -lt $TIMEOUT ]; do
          if docker logs ${CONTAINER_NAME} 2>&1 | grep -q "Completed initialization in" || docker logs ${CONTAINER_NAME} 2>&1 | grep -q "Started.*in.*seconds"; then              INITIALIZED=true
              echo "✅ Modulo ${module_to_deploy} inizializzato correttamente!"
              break
          fi
          echo -n "." # Mostra un indicatore di progresso
          sleep 2
      done

      echo "" # Nuova riga dopo i punti di progresso

      # Mostra i log indipendentemente dall'esito dell'inizializzazione
      echo "=== Prime righe di log del servizio ${module_to_deploy} ==="
      docker logs --tail 20 ${CONTAINER_NAME}
      echo "=========================================="

      # Verifica se l'inizializzazione è avvenuta con successo
      if [ "$INITIALIZED" = true ]; then
          echo "=== Deploy di $module_to_deploy (tag: ${LATEST_TAG:-N/A}) completato con successo $(date) ==="
          return 0
      else
          echo "Errore: Il modulo ${module_to_deploy} non si è inizializzato correttamente entro ${TIMEOUT} secondi."
          echo "=== Deploy di $module_to_deploy (tag: ${LATEST_TAG:-N/A}) fallito $(date) ==="
          return 1
      fi
  else
      echo "Errore: Container ${CONTAINER_NAME} non trovato in esecuzione dopo 'up -d'."
      echo "=== Deploy di $module_to_deploy (tag: ${LATEST_TAG:-N/A}) fallito $(date) ==="
      echo "Ultime righe di log del container (se disponibili):"
      docker logs --tail 50 ${CONTAINER_NAME} 2>/dev/null || echo "Nessun log disponibile"
      return 1 # Ritorna un codice di errore
  fi
}

# --- Funzione deploy_all ---
deploy_all() {
  # I parametri globali e script sono già stati caricati all'inizio
  if [[ -z "$MODULE_ORDER" ]]; then
      echo "Errore: MODULE_ORDER non definito nell'ambiente. Impossibile procedere con 'all'."
      exit 1
  fi
  echo "Ordine di deploy definito: $MODULE_ORDER"

  local deploy_failed=0
  local deployed_modules=()
  local failed_modules=()

  for module in $MODULE_ORDER; do
    # Chiama deploy_module (che ora recupera i suoi parametri specifici)
    if deploy_module "$module"; then
        deployed_modules+=("$module")
    else
        echo "❌ Deploy del modulo $module fallito."
        failed_modules+=("$module")
        deploy_failed=1
        # break # Decommenta per interrompere al primo fallimento
    fi

    # Attendi tra i deploy se necessario
    if [[ $deploy_failed -eq 0 ]]; then
        echo "Attesa di 15 secondi prima del prossimo modulo..."
        sleep 15
    else
        echo "Fallimento rilevato, procedo al prossimo modulo (se non interrotto)..."
        sleep 5 # Breve attesa anche in caso di fallimento
    fi
  done

  echo ""
  echo "--- Riepilogo Deploy 'all' ---"
  if [ ${#deployed_modules[@]} -gt 0 ]; then
      echo "✅ Moduli deployati con successo: ${deployed_modules[*]}"
  fi
  if [ ${#failed_modules[@]} -gt 0 ]; then
      echo "oduli falliti: ${failed_modules[*]}"
  fi
  echo "-----------------------------"

  if [ $deploy_failed -eq 1 ]; then
      echo "⚠️ Uno o più moduli non sono stati deployati correttamente."
      exit 1 # Esce con errore se almeno un modulo è fallito
  fi
}

# --- Logica Principale ---

# Assicura che la rete Docker esista
echo "Assicurazione esistenza rete Docker auxdromos-network..."
docker network create auxdromos-network >/dev/null 2>&1 || echo "Info: Rete auxdromos-network già esistente o errore nella creazione ignorato."

# Recupera il nome del modulo passato come primo argomento
MODULO_ARG=$1

if [[ -z "$MODULO_ARG" ]]; then
  echo "Errore: nessun modulo specificato. Specificare un modulo o 'all' per deployare tutto."
  # Potremmo leggere MODULES da SSM qui, ma per ora lo lasciamo hardcoded nell'errore
  echo "Esempio Moduli: config rdbms keycloak gateway backend idp"
  exit 1
fi

echo "=== Inizio deploy di '$MODULO_ARG' $(date) ==="

# --- CARICA PARAMETRI GLOBALI E SCRIPT UNA SOLA VOLTA ALL'INIZIO ---
echo "Recupero configurazione iniziale da AWS Systems Manager Parameter Store..."
# 1. Determina Regione - Logica migliorata per funzionare sia in locale che su EC2
echo "Determinazione della regione AWS..."

# Verifica se AWS_DEFAULT_REGION è già impostata nell'ambiente
if [[ -n "${AWS_DEFAULT_REGION}" ]]; then
    echo "Utilizzando la regione AWS dall'ambiente: ${AWS_DEFAULT_REGION}"
else
    # Se non è impostata, prova a determinarla dai metadati EC2
    echo "AWS_DEFAULT_REGION non impostata. Tentativo di rilevare la regione dai metadati EC2..."

    # Usa un timeout ridotto per evitare attese lunghe in ambiente locale
    EC2_REGION=$(curl -s --connect-timeout 1 --max-time 1 http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region 2>/dev/null)

    # Verifica se la regione è stata recuperata con successo
    if [[ -n "$EC2_REGION" && "$EC2_REGION" != "null" ]]; then
        echo "Regione rilevata dai metadati EC2: ${EC2_REGION}"
        AWS_DEFAULT_REGION="$EC2_REGION"
    else
        echo "Attenzione: Impossibile determinare la regione dai metadati EC2."
        echo "Impostazione della regione predefinita a us-east-1."
        echo "Per utilizzare una regione diversa, impostare la variabile d'ambiente AWS_DEFAULT_REGION."

        # Imposta us-east-1 come default
        AWS_DEFAULT_REGION="us-east-1"
    fi
fi

# Esporta la regione per i comandi successivi
export AWS_DEFAULT_REGION
echo "Regione AWS in uso: ${AWS_DEFAULT_REGION}"

# 2. Carica Parametri Globali
echo "Caricamento parametri globali da ${GLOBAL_PARAM_PATH}..."
if ! fetch_and_export_params "$GLOBAL_PARAM_PATH" "$AWS_DEFAULT_REGION"; then
    echo "Errore Critico nel recupero dei parametri globali da ${GLOBAL_PARAM_PATH}. Impossibile procedere."
    exit 1
fi
echo "Parametri globali caricati con successo."

# 3. Carica Parametri Script
echo "Caricamento parametri di script da ${SCRIPT_PARAM_PATH}..."
if ! fetch_and_export_params "$SCRIPT_PARAM_PATH" "$AWS_DEFAULT_REGION"; then
    echo "Attenzione: Errore nel recupero dei parametri dello script da ${SCRIPT_PARAM_PATH}. Alcune funzionalità potrebbero usare valori di default."
    # Imposta default essenziali se SSM fallisce e stiamo facendo 'all'
    if [[ "$MODULO_ARG" == "all" && -z "$MODULE_ORDER" ]]; then
        echo "Imposto MODULE_ORDER di default: config rdbms keycloak idp backend gateway"
        export MODULE_ORDER="config rdbms keycloak idp backend gateway"
    fi
else
    # Se MODULE_ORDER non è stato caricato nemmeno con successo, imposta default
     if [[ "$MODULO_ARG" == "all" && -z "$MODULE_ORDER" ]]; then
        echo "Attenzione: MODULE_ORDER vuoto dopo recupero da SSM. Imposto default."
        export MODULE_ORDER="config rdbms keycloak idp backend gateway"
    fi
fi
echo "Configurazione iniziale caricata."
# --- FINE CARICAMENTO INIZIALE ---


# Esegui l'azione richiesta
if [[ "$MODULO_ARG" == "all" ]]; then
  deploy_all
elif [[ "$MODULO_ARG" == "keycloak" ]]; then
  # Se vuoi usare la funzione separata deploy_keycloak (con docker run):
  # deploy_keycloak
  # Altrimenti, se è gestito da compose come gli altri:
  deploy_module "$MODULO_ARG"
else
  # Deploy di un modulo singolo gestito da compose
  deploy_module "$MODULO_ARG"
fi

# Controlla lo stato di uscita dell'ultima operazione (deploy_all o deploy_module)
exit_status=$?

echo ""
echo "========================================="
if [ $exit_status -eq 0 ]; then
  echo "=== Deploy di '$MODULO_ARG' completato con successo $(date) ==="
else
  echo "=== Deploy di '$MODULO_ARG' terminato con errori $(date) ==="
fi
echo "========================================="

exit $exit_status # Esce con lo stato dell'ultima operazione
