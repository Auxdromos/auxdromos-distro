#!/bin/bash

# --- Configurazione di base ---
if [ -z "$1" ]; then
  echo "❌ Specificare un profilo Spring Boot (es: dev, sit, uat)"
  echo "Esempio: ./start-tunnel-and-run.sh sit"
  exit 1
fi
SPRING_PROFILE=$1

KEY="$HOME/.ssh/Ec2-sit-new.pem"
EC2_USER="ec2-user"
EC2_HOST="34.232.141.149"
RDS_HOST="sit-auxdromos.cjgmm0kewpv2.us-east-1.rds.amazonaws.com"
LOCAL_PORT=5463
REMOTE_PORT=5432

# --- Funzione per check porta ---
is_port_open() {
  # Restituisce 0 se la porta è in uso da qualche processo in LISTEN
  lsof -iTCP:"$1" -sTCP:LISTEN -t &>/dev/null
}

echo "🔌 Verifica tunnel sulla porta locale $LOCAL_PORT..."
if is_port_open $LOCAL_PORT; then
  echo "✅ Tunnel già attivo su localhost:$LOCAL_PORT, salto la creazione."
  TUNNEL_PID=$(lsof -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -t)
else
  echo "🔌 Avvio tunnel SSH verso $RDS_HOST..."
  # -o ExitOnForwardFailure=yes fa fallire subito se non riesce a bindare la porta
  # -fN manda ssh in background in modo silenzioso
  ssh -i "$KEY" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=60 \
      -fN \
      -L "$LOCAL_PORT":"$RDS_HOST":"$REMOTE_PORT" \
      "$EC2_USER"@"$EC2_HOST"
  TUNNEL_PID=$(pgrep -f "ssh.*-L $LOCAL_PORT:$RDS_HOST:$REMOTE_PORT")
  sleep 1
  echo "🔐 Tunnel avviato (PID: $TUNNEL_PID)"
fi

# --- Avvio dell’applicazione Spring Boot ---
echo "🚀 Avvio Spring Boot con profilo: $SPRING_PROFILE..."
mvn spring-boot:run -Dspring-boot.run.profiles="$SPRING_PROFILE"

# --- Al termine, chiudo il tunnel solo se l’ho creato io ora ---
if ! is_port_open $LOCAL_PORT; then
  # non c’è tunnel, niente da chiudere
  exit 0
fi

# Se il PID che abbiamo salvato corrisponde a un processo ssh che fa il forward,
# lo terminiamo (potrebbe essere già terminato se l’utente ha stoppato tutto).
if ps -p "$TUNNEL_PID" &>/dev/null; then
  echo "🛑 Arresto tunnel SSH (PID: $TUNNEL_PID)..."
  kill "$TUNNEL_PID"
else
  echo "ℹ️ Tunnel già chiuso o PID non valido."
fi
