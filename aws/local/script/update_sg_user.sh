#!/bin/bash
# Script per aggiornare la regola SSH nel Security Group specifico per ogni utente

PORT=22
PROTOCOL="tcp"

# Funzione per ottenere il security group ID in base all'utente
get_security_group_id() {
    local user=$1
    case "$user" in
        "Massimiliano")
            echo "sg-0fb13050d63838c85"
            ;;
        "Simone")
            echo "sg-0fb13050d63838c85"
            ;;
        "Daniele")
            echo "sg-0fb13050d63838c85"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Funzione per ottenere l'SGR ID per un utente
get_user_sgr_id() {
    local user=$1
    case "$user" in
        "Massimiliano")
            echo "sgr-088c5029b14b11f7b"  # ID aggiornato da output
            ;;
        "Simone")
            echo "sgr-097ad2ffea945515e"  # Sostituire con l'SGR ID reale
            ;;
        "Daniele")
            echo "sgr-0fdd18071d3c11703"  # ID aggiornato da output precedente
            ;;
        *)
            echo ""
            ;;
    esac
}

# Utenti autorizzati
AUTHORIZED_USERS=("Massimiliano" "Simone" "Daniele")

# Controllo parametri
if [ $# -ne 1 ]; then
    echo "Uso: $0 <NomeUtente> Possibili valori: ${AUTHORIZED_USERS[*]}"
    exit 1
fi

USER="$1"
DESCRIPTION="${USER}"

# Verifica che l'utente sia autorizzato
USER_OK=false
for valid_user in "${AUTHORIZED_USERS[@]}"; do
    if [ "$USER" == "$valid_user" ]; then
        USER_OK=true
        break
    fi
done

if [ "$USER_OK" = false ]; then
    echo "Utente non autorizzato: $USER. Possibili valori: ${AUTHORIZED_USERS[*]}"
    exit 2
fi

# Ottieni il security group ID per l'utente
SECURITY_GROUP_ID=$(get_security_group_id "$USER")
if [ -z "$SECURITY_GROUP_ID" ]; then
    echo "Security Group ID non configurato per l'utente $USER"
    exit 3
fi

# Ottieni il tuo IP pubblico
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
if [ -z "$MY_IP" ]; then
    echo "Impossibile determinare l'IP pubblico."
    exit 4
fi
NEW_CIDR="${MY_IP}/32"
echo "Il tuo IP attuale è: $NEW_CIDR"
echo "Usando Security Group ID: $SECURITY_GROUP_ID per l'utente $USER"

# Ottieni l'SGR ID esistente per l'utente
USER_SGR_ID=$(get_user_sgr_id "$USER")

echo "Verificando regole esistenti..."

# Funzione per verificare se una regola esiste e ottenere dettagli
check_rule() {
    local rule_id=$1

    if [ -z "$rule_id" ]; then
        return 1
    fi

    local rule_info=$(aws ec2 describe-security-group-rules \
                     --security-group-rule-ids "$rule_id" \
                     --output json 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$rule_info" ]; then
        return 1
    fi

    echo "$rule_info"
    return 0
}

# Funzione per cercare regole con un IP specifico
find_rule_by_ip() {
    local group_id=$1
    local ip_cidr=$2
    local port=$3

    # Ottieni tutte le regole del security group
    local all_rules=$(aws ec2 describe-security-group-rules \
                      --filters "Name=group-id,Values=${group_id}" \
                      --output json 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "Errore nel recupero delle regole per il gruppo $group_id"
        return 1
    fi

    # Trova regole con IP e porta specifici
    local rule_id=$(echo "$all_rules" | jq -r --arg ip "$ip_cidr" --arg port "$port" \
                   '.SecurityGroupRules[] |
                    select(.IsEgress==false and .CidrIpv4==$ip and .FromPort==($port|tonumber)) |
                    .SecurityGroupRuleId' 2>/dev/null | head -1)

    echo "$rule_id"
}

# Cerca prima se esiste già una regola con il nuovo IP
EXISTING_RULE_WITH_NEW_IP=$(find_rule_by_ip "$SECURITY_GROUP_ID" "$NEW_CIDR" "$PORT")

if [ -n "$EXISTING_RULE_WITH_NEW_IP" ]; then
    echo "Trovata regola esistente con il tuo IP attuale ($NEW_CIDR):"

    RULE_INFO=$(check_rule "$EXISTING_RULE_WITH_NEW_IP")
    EXISTING_DESC=$(echo "$RULE_INFO" | jq -r '.SecurityGroupRules[0].Description // ""' 2>/dev/null)

    echo "  ID: $EXISTING_RULE_WITH_NEW_IP"
    echo "  Descrizione: $EXISTING_DESC"

    if [ "$EXISTING_DESC" == "$DESCRIPTION" ]; then
        echo "La regola ha già la descrizione corretta ($DESCRIPTION)."

        # Verifica se questa è già la regola associata all'utente
        if [ "$EXISTING_RULE_WITH_NEW_IP" == "$USER_SGR_ID" ]; then
            echo "Questa è già la regola associata all'utente $USER. Nessuna modifica necessaria."
            exit 0
        else
            echo "Aggiornando la configurazione locale per associare l'utente $USER a questa regola esistente."
            echo ""
            echo "IMPORTANTE: È necessario aggiornare la funzione get_user_sgr_id nel codice"
            echo "Per l'utente $USER, usa l'SGR ID: $EXISTING_RULE_WITH_NEW_IP"
            echo "Modifica la riga nel case statement per '$USER'"
            exit 0
        fi
    else
        echo "La regola ha una descrizione diversa: '$EXISTING_DESC'."

        if [ -n "$USER_SGR_ID" ]; then
            # Verifica che la vecchia regola dell'utente esista ancora
            OLD_RULE_INFO=$(check_rule "$USER_SGR_ID")

            if [ $? -eq 0 ]; then
                # La vecchia regola esiste ancora, quindi va rimossa
                echo "Rimuovendo la vecchia regola dell'utente con ID $USER_SGR_ID..."

                REMOVE_RESULT=$(aws ec2 revoke-security-group-ingress \
                    --group-id "$SECURITY_GROUP_ID" \
                    --security-group-rule-ids "$USER_SGR_ID" \
                    --output json 2>&1)

                if [ $? -eq 0 ]; then
                    echo "Vecchia regola rimossa con successo."
                else
                    echo "Errore durante la rimozione della vecchia regola:"
                    echo "$REMOVE_RESULT"
                fi
            else
                echo "La vecchia regola con ID $USER_SGR_ID non esiste più."
            fi
        fi

        # Aggiorna la descrizione della regola con il nuovo IP
        echo "Aggiornando la descrizione della regola con il tuo IP..."

        UPDATE_RESULT=$(aws ec2 modify-security-group-rules \
            --group-id "$SECURITY_GROUP_ID" \
            --security-group-rules "SecurityGroupRuleId=$EXISTING_RULE_WITH_NEW_IP,SecurityGroupRule={Description='$DESCRIPTION'}" \
            --output json 2>&1)

        if [ $? -eq 0 ]; then
            echo "Descrizione regola aggiornata con successo."
            echo "Aggiornando la configurazione locale per l'utente $USER con SGR ID: $EXISTING_RULE_WITH_NEW_IP"
            echo ""
            echo "IMPORTANTE: È necessario aggiornare manualmente la funzione get_user_sgr_id nel codice"
            echo "Per l'utente $USER, usa l'SGR ID: $EXISTING_RULE_WITH_NEW_IP"
            echo "Modifica la riga nel case statement per '$USER' nella funzione get_user_sgr_id"
            exit 0
        else
            echo "Errore nell'aggiornare la descrizione:"
            echo "$UPDATE_RESULT"
            echo "Potrebbe essere necessario gestire manualmente questa situazione."
            exit 5
        fi
    fi
fi

# Se arriviamo qui, non c'è una regola con il nostro IP corrente
if [ -n "$USER_SGR_ID" ]; then
    echo "Trovato SGR ID per $USER: $USER_SGR_ID. Verificando validità..."

    # Verifica che la regola esista ancora
    RULE_INFO=$(check_rule "$USER_SGR_ID")

    if [ $? -eq 0 ]; then
        # Estrai i dettagli della regola
        RULE_CIDR=$(echo "$RULE_INFO" | jq -r '.SecurityGroupRules[0].CidrIpv4' 2>/dev/null)
        RULE_DESC=$(echo "$RULE_INFO" | jq -r '.SecurityGroupRules[0].Description // "nessuna descrizione"' 2>/dev/null)
        RULE_PORT=$(echo "$RULE_INFO" | jq -r '.SecurityGroupRules[0].FromPort' 2>/dev/null)

        echo "Regola esistente trovata per $USER:"
        echo "  ID: $USER_SGR_ID"
        echo "  IP: $RULE_CIDR"
        echo "  Porta: $RULE_PORT"
        echo "  Descrizione: $RULE_DESC"

        # Se la regola ha l'IP corrente, non serve cambiarla
        if [ "$RULE_CIDR" == "$NEW_CIDR" ]; then
            echo "La regola ha già l'IP corretto. Nessuna modifica necessaria."
            exit 0
        else
            echo "La regola ha un IP diverso. Tentativo di modifica diretta..."

            # Tenta di modificare la regola esistente
            UPDATE_RESULT=$(aws ec2 modify-security-group-rules \
                --group-id "$SECURITY_GROUP_ID" \
                --security-group-rules "SecurityGroupRuleId=$USER_SGR_ID,SecurityGroupRule={IpProtocol=$PROTOCOL,FromPort=$PORT,ToPort=$PORT,CidrIpv4=$NEW_CIDR,Description='$DESCRIPTION'}" \
                --output json 2>&1)

            # Se la modifica fallisce per duplicazione, tenta una strategia diversa
            if echo "$UPDATE_RESULT" | grep -q "InvalidPermission.Duplicate"; then
                echo "Impossibile modificare la regola: esiste già una regola con questo IP."
                echo "Questo è strano poiché abbiamo già verificato che non ci sono regole con il tuo IP."
                echo "Verifica manualmente e correggi il problema."
                exit 6
            elif [ $? -eq 0 ]; then
                echo "Regola aggiornata con successo per l'utente $USER con nuovo IP $NEW_CIDR"
                echo "ID regola (invariato): $USER_SGR_ID"
                exit 0
            else
                echo "Errore durante l'aggiornamento della regola:"
                echo "$UPDATE_RESULT"
                echo "Procedendo con l'approccio elimina e ricrea..."
            fi

            # Se siamo qui, dobbiamo eliminare e ricreare
            echo "Rimuovendo la vecchia regola con ID $USER_SGR_ID..."

            REMOVE_RESULT=$(aws ec2 revoke-security-group-ingress \
                --group-id "$SECURITY_GROUP_ID" \
                --security-group-rule-ids "$USER_SGR_ID" \
                --output json 2>&1)

            if [ $? -ne 0 ]; then
                echo "Errore durante la rimozione della vecchia regola:"
                echo "$REMOVE_RESULT"
            else
                echo "Vecchia regola rimossa con successo."
            fi
        fi
    else
        echo "La regola con ID $USER_SGR_ID non esiste più o è invalida."
    fi
else
    echo "Nessun SGR ID trovato per l'utente $USER."
fi

# Se siamo arrivati qui, dobbiamo creare una nuova regola
echo "Aggiungendo nuova regola con IP $NEW_CIDR per utente $USER..."

NEW_RULE=$(aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --ip-permissions "[{\"IpProtocol\":\"$PROTOCOL\",\"FromPort\":$PORT,\"ToPort\":$PORT,\"IpRanges\":[{\"CidrIp\":\"$NEW_CIDR\",\"Description\":\"$DESCRIPTION\"}]}]" \
    --output json 2>&1)

if [ $? -eq 0 ]; then
    # Estrai l'ID della nuova regola
    NEW_RULE_ID=$(echo "$NEW_RULE" | jq -r '.SecurityGroupRules[0].SecurityGroupRuleId' 2>/dev/null)

    if [ -n "$NEW_RULE_ID" ]; then
        echo "Regola aggiunta con successo per l'utente $USER con IP $NEW_CIDR"
        echo "ID della nuova regola: $NEW_RULE_ID"
        echo ""
        echo "IMPORTANTE: È necessario aggiornare manualmente la funzione get_user_sgr_id nel codice"
        echo "Per l'utente $USER, usa l'SGR ID: $NEW_RULE_ID"
        echo "Modifica la riga nel case statement per '$USER' nella funzione get_user_sgr_id"
    else
        echo "La regola è stata aggiunta ma non è stato possibile estrarre l'ID."
        echo "Output dell'operazione di aggiunta:"
        echo "$NEW_RULE"
    fi
else
    if echo "$NEW_RULE" | grep -q "InvalidPermission.Duplicate"; then
        echo "Una regola con questo IP e porta esiste già."

        # Cerca nuovamente la regola
        echo "Cercando nuovamente la regola esistente..."
        EXISTING_RULE_ID=$(find_rule_by_ip "$SECURITY_GROUP_ID" "$NEW_CIDR" "$PORT")

        if [ -n "$EXISTING_RULE_ID" ]; then
            echo "Identificata regola esistente con ID: $EXISTING_RULE_ID"
            echo "Aggiornando la configurazione locale per l'utente $USER con SGR ID: $EXISTING_RULE_ID"
            echo ""
            echo "IMPORTANTE: È necessario aggiornare manualmente la funzione get_user_sgr_id nel codice"
            echo "Per l'utente $USER, usa l'SGR ID: $EXISTING_RULE_ID"
            echo "Modifica la riga nel case statement per '$USER' nella funzione get_user_sgr_id"
        else
            echo "Impossibile trovare la regola esistente. Questo è inaspettato."
            echo "Verifica manualmente lo stato delle regole di sicurezza."
        fi
    else
        echo "Errore durante l'aggiunta della regola:"
        echo "$NEW_RULE"
    fi
fi

exit 0