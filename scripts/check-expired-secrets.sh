#!/bin/bash

set -euo pipefail

OUTPUT_FILE="expired.txt"

# Clear previous output
> "$OUTPUT_FILE"

CURRENT_EPOCH=$(date -u +%s)
FOUND_COUNT=0

echo "========================================="
echo "Checking for expired App Registration secrets..."
echo "Current UTC Time: $(date -u)"
echo "========================================="
echo

az ad app list --all -o json | jq -c '.[]' | while read -r app; do

    APP_NAME=$(echo "$app" | jq -r '.displayName')
    APP_ID=$(echo "$app" | jq -r '.appId')
    OBJECT_ID=$(echo "$app" | jq -r '.id')

    az ad app show \
        --id "$OBJECT_ID" \
        --query "passwordCredentials" \
        -o json 2>/dev/null | jq -c '.[]?' | while read -r secret; do

        SECRET_ID=$(echo "$secret" | jq -r '.keyId')
        EXPIRY_DATE=$(echo "$secret" | jq -r '.endDateTime')

        [ -z "$EXPIRY_DATE" ] && continue
        [ "$EXPIRY_DATE" = "null" ] && continue

        EXPIRY_EPOCH=$(date -u -d "$EXPIRY_DATE" +%s 2>/dev/null || echo 0)

        if [ "$EXPIRY_EPOCH" -lt "$CURRENT_EPOCH" ]; then

            {
                echo "========================================="
                echo "App Name        : $APP_NAME"
                echo "App ID          : $APP_ID"
                echo "Object ID       : $OBJECT_ID"
                echo "Secret Key ID   : $SECRET_ID"
                echo "Expiry Date UTC : $EXPIRY_DATE"
                echo
            } >> "$OUTPUT_FILE"

            echo "FOUND: Expired secret in '$APP_NAME' ($APP_ID)"

        fi

    done

done

FOUND_COUNT=$(grep -c "^App Name" "$OUTPUT_FILE" 2>/dev/null || echo 0)

echo
echo "========================================="
echo "Completed."
echo "Total expired secrets found: $FOUND_COUNT"
echo "Results saved to: $OUTPUT_FILE"
echo "========================================="