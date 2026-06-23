#!/bin/bash

OUTPUT_FILE="expired.txt"

# Clear previous output

> "$OUTPUT_FILE"

CURRENT_EPOCH=$(date -u +%s)

echo "Checking for expired App Registration secrets..."
echo "Current UTC Time: $(date -u)"
echo

az ad app list --all -o json | jq -c '.[]' | while read -r app; do

```
APP_NAME=$(echo "$app" | jq -r '.displayName')
APP_ID=$(echo "$app" | jq -r '.appId')
OBJECT_ID=$(echo "$app" | jq -r '.id')

az ad app show --id "$OBJECT_ID" --query "passwordCredentials" -o json 2>/dev/null | \
jq -c '.[]?' | while read -r secret; do

    SECRET_ID=$(echo "$secret" | jq -r '.keyId')
    EXPIRY_DATE=$(echo "$secret" | jq -r '.endDateTime')

    [ -z "$EXPIRY_DATE" ] && continue

    EXPIRY_EPOCH=$(date -u -d "$EXPIRY_DATE" +%s 2>/dev/null)

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

        echo "Expired secret found in: $APP_NAME"
    fi

done
```

done

echo
echo "Completed."
echo "Results saved to: $OUTPUT_FILE"
