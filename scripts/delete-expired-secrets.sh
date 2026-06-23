#!/bin/bash

INPUT_FILE="expired.txt"

echo "Starting deletion of expired secrets..."
echo

while read -r line; do

```
# Extract Object ID
if [[ "$line" == Object\ ID* ]]; then
    OBJECT_ID=$(echo "$line" | awk -F: '{print $2}' | xargs)
fi

# Extract Secret Key ID
if [[ "$line" == Secret\ Key\ ID* ]]; then
    SECRET_ID=$(echo "$line" | awk -F: '{print $2}' | xargs)

    echo "Deleting secret:"
    echo "  Object ID : $OBJECT_ID"
    echo "  Secret ID : $SECRET_ID"

    az ad app credential delete \
        --id "$OBJECT_ID" \
        --key-id "$SECRET_ID"

    echo "Deleted successfully"
    echo "--------------------------------------"
fi
```

done < "$INPUT_FILE"

echo
echo "All expired secrets processed."
