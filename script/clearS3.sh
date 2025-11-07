#!/bin/bash
echo "🧹 S3 CLEANUP - Mantiene ULTIME 5 versioni per ogni servizio"
echo "==========================================================="
echo ""

# Lista tutti i bucket
BUCKETS=$(aws s3api list-buckets --query 'Buckets[].Name' --output text)

for BUCKET in $BUCKETS; do
  echo "📦 BUCKET: $BUCKET"
  echo ""

  # Lista servizi nel bucket
  SERVICES=$(aws s3api list-objects-v2 \
    --bucket $BUCKET \
    --delimiter "/" \
    --query 'CommonPrefixes[].Prefix' \
    --output text 2>/dev/null | tr '\t' '\n' | sed 's/\///' | grep -v "^$")

  if [ -z "$SERVICES" ]; then
    echo "   ℹ️  No services found - skipping"
    echo ""
    continue
  fi

  BUCKET_DELETE_COUNT=0

  for SERVICE in $SERVICES; do
    echo "   🔧 SERVICE: $SERVICE"

    # Scarica latest.json in file temporaneo
    TEMP_JSON="/tmp/latest_$SERVICE.json"
    aws s3api get-object \
      --bucket $BUCKET \
      --key $SERVICE/latest.json \
      $TEMP_JSON 2>/dev/null

    if [ ! -f "$TEMP_JSON" ]; then
      echo "      ⏭️  No latest.json found"
      continue
    fi

    # Parse con jq da file
    LATEST_VERSION=$(jq -r '.latestVersion // empty' $TEMP_JSON 2>/dev/null)
    rm -f $TEMP_JSON

    if [ -z "$LATEST_VERSION" ]; then
      echo "      ⏭️  Could not parse latestVersion"
      continue
    fi

    echo "      Latest version: $LATEST_VERSION"

    # Estrai numero (es: 0.0.117 → 117)
    LATEST_NUM=$(echo "$LATEST_VERSION" | sed 's/.*\.//')

    # Calcola range (ultime 5)
    KEEP_FROM=$((LATEST_NUM - 4))

    echo "      Keeping: 0.0.$KEEP_FROM → 0.0.$LATEST_NUM"

    # Lista versioni
    VERSIONS=$(aws s3api list-objects-v2 \
      --bucket $BUCKET \
      --prefix "$SERVICE/" \
      --delimiter "/" \
      --query 'CommonPrefixes[].Prefix' \
      --output text 2>/dev/null | tr '\t' '\n' | sed "s|$SERVICE/||" | sed 's/\///' | grep "^0\.0\." | sort -V)

    if [ -z "$VERSIONS" ]; then
      echo "      ℹ️  No versioned folders"
      continue
    fi

    # Conta e identifica da eliminare
    DELETE_LIST=""
    KEEP_LIST=""

    for VERSION in $VERSIONS; do
      VERSION_NUM=$(echo "$VERSION" | sed 's/.*\.//')

      if [ "$VERSION_NUM" -lt "$KEEP_FROM" ]; then
        DELETE_LIST="$DELETE_LIST $VERSION"
      else
        KEEP_LIST="$KEEP_LIST $VERSION"
      fi
    done

    DELETE_COUNT=$(echo $DELETE_LIST | wc -w)
    KEEP_COUNT=$(echo $KEEP_LIST | wc -w)

    echo "      Delete: $DELETE_COUNT, Keep: $KEEP_COUNT"

    if [ "$DELETE_COUNT" -gt 0 ]; then
      for VERSION in $DELETE_LIST; do
        echo "        🗑️  $VERSION"
      done

      read -p "      Proceed? (yes/no): " CONFIRM

      if [ "$CONFIRM" = "yes" ]; then
        for VERSION in $DELETE_LIST; do
          echo "        Deleting s3://$BUCKET/$SERVICE/$VERSION/"

          # Lista tutti gli oggetti nel path e cancellali uno per uno
          OBJECT_COUNT=$(aws s3api list-objects-v2 \
            --bucket $BUCKET \
            --prefix "$SERVICE/$VERSION/" \
            --query 'Contents | length(@)' 2>/dev/null || echo "0")

          if [ "$OBJECT_COUNT" -gt 0 ]; then
            # Cancella gli oggetti usando delete-objects batch (massimo 1000 per request)
            aws s3api delete-objects \
              --bucket $BUCKET \
              --delete "$(aws s3api list-objects-v2 \
                --bucket $BUCKET \
                --prefix "$SERVICE/$VERSION/" \
                --output=json \
                --query='Contents[].{Key:Key}' 2>/dev/null | jq -c '{Objects:(.)}' 2>/dev/null)" 2>/dev/null

            # Verifica che sia stata cancellata
            REMAINING=$(aws s3api list-objects-v2 \
              --bucket $BUCKET \
              --prefix "$SERVICE/$VERSION/" \
              --query 'Contents | length(@)' 2>/dev/null || echo "0")

            if [ "$REMAINING" -eq 0 ]; then
              echo "        ✅ $VERSION deleted successfully ($OBJECT_COUNT objects removed)"
              ((BUCKET_DELETE_COUNT++))
            else
              echo "        ❌ $VERSION deletion FAILED - $REMAINING objects still remaining!"
            fi
          else
            echo "        ℹ️  $VERSION is empty (0 objects)"
            ((BUCKET_DELETE_COUNT++))
          fi
        done
        echo "      ✅ Batch complete!"
      else
        echo "      ⏭️  Skipped"
      fi
    else
      echo "      ℹ️  Nothing to delete"
    fi

    echo ""
  done

  if [ "$BUCKET_DELETE_COUNT" -gt 0 ]; then
    echo "   ✅ Total cleaned up from $BUCKET: $BUCKET_DELETE_COUNT versions"
    echo ""
    echo "   New size:"
    aws s3 ls s3://$BUCKET --recursive --summarize 2>/dev/null | grep "Total Size\|Total Objects"
  fi

  echo ""
  echo "---"
  echo ""
done

echo "🎉 CLEANUP COMPLETE!"