#!/bin/bash

# --- Configurazione di base ---
LOCAL_PORT=5463

# --- Funzione per check porta ---
is_port_open() {
  # Restituisce 0 se la porta è in uso da qualche processo in LISTEN
  lsof -iTCP:"$1" -sTCP:LISTEN -t &>/dev/null
}

echo "🔌 Verifica tunnel sulla porta locale $LOCAL_PORT..."
if is_port_open $LOCAL_PORT; then
  TUNNEL_PID=$(lsof -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -t)
  echo "🔌 Chiusura tunnel SSH (PID: $TUNNEL_PID)..."
  kill $TUNNEL_PID
  sleep 1
  
  # Verifica che il tunnel sia stato effettivamente chiuso
  if ! is_port_open $LOCAL_PORT; then
    echo "✅ Tunnel chiuso con successo."
  else
    echo "❌ Impossibile chiudere il tunnel. Prova a terminare il processo manualmente."
    exit 1
  fi
else
  echo "ℹ️ Nessun tunnel attivo sulla porta $LOCAL_PORT."
fi

echo "✅ Operazione completata."