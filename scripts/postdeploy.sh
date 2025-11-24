#!/bin/bash

echo "Post-deployment script started."

# Load azd environment values
eval "$(azd env get-values)"

# Check for function app name (could be FUNCTION_APP_NAME or PROCESSING_FUNCTION_APP_NAME)
FUNCTION_APP_NAME="${FUNCTION_APP_NAME:-$PROCESSING_FUNCTION_APP_NAME}"

# Check if Flex Consumption is enabled from environment variable (set by azd from Bicep output)
IS_FLEX_CONSUMPTION=false

if [ -n "$FUNCTION_APP_PLAN_TYPE" ]; then
    echo "FUNCTION_APP_PLAN_TYPE from environment: $FUNCTION_APP_PLAN_TYPE"
    if [ "$FUNCTION_APP_PLAN_TYPE" = "FlexConsumption" ]; then
        IS_FLEX_CONSUMPTION=true
        echo "Flex Consumption plan detected from environment variable."
    fi
elif [ -n "$FUNCTION_APP_NAME" ]; then
    # Fallback: Try to determine from function app configuration
    echo "FUNCTION_APP_PLAN_TYPE not in environment. Checking function app app settings..."
    PLAN_TYPE=$(az functionapp config appsettings list \
        --name "$FUNCTION_APP_NAME" \
        --resource-group "$RESOURCE_GROUP" \
        --query "[?name=='FUNCTION_APP_PLAN_TYPE'].value" \
        -o tsv 2>&1)
    
    if [ $? -eq 0 ] && [ -n "$PLAN_TYPE" ] && [ "$PLAN_TYPE" = "FlexConsumption" ]; then
        IS_FLEX_CONSUMPTION=true
        echo "Flex Consumption plan detected from function app app settings."
    fi
else
    echo "Cannot determine plan type: function app name not found."
fi

if [ "$IS_FLEX_CONSUMPTION" = true ] && [ -n "$FUNCTION_APP_NAME" ]; then
    echo "Creating Event Grid subscription for Flex Consumption blob triggers..."
    echo "Function App: $FUNCTION_APP_NAME"
    
    RESOURCE_GROUP="${RESOURCE_GROUP:-}"
    STORAGE_ACCOUNT_NAME="${AZURE_STORAGE_ACCOUNT:-}"
    
    if [ -z "$RESOURCE_GROUP" ]; then
        echo "WARNING: RESOURCE_GROUP environment variable is not set. Skipping Event Grid subscription creation."
        exit 0
    fi
    
    if [ -z "$STORAGE_ACCOUNT_NAME" ]; then
        echo "WARNING: AZURE_STORAGE_ACCOUNT environment variable is not set. Skipping Event Grid subscription creation."
        exit 0
    fi
    
    # Get blob extension key with retry logic
    echo "Retrieving blob extension key for function app: $FUNCTION_APP_NAME"
    MAX_RETRIES=5
    RETRY_DELAY=10
    BLOB_EXTENSION_KEY=""
    
    for attempt in $(seq 1 $MAX_RETRIES); do
        echo "Attempt $attempt of $MAX_RETRIES to retrieve blob extension key..."
        KEYS_RESULT=$(az functionapp keys list \
            --name "$FUNCTION_APP_NAME" \
            --resource-group "$RESOURCE_GROUP" \
            -o json 2>&1)
        
        if [ $? -eq 0 ]; then
            BLOB_EXTENSION_KEY=$(echo "$KEYS_RESULT" | jq -r '.systemKeys.blobs_extension // empty' 2>/dev/null)
            if [ -n "$BLOB_EXTENSION_KEY" ] && [ "$BLOB_EXTENSION_KEY" != "null" ]; then
                BLOB_EXTENSION_KEY=$(echo "$BLOB_EXTENSION_KEY" | tr -d '[:space:]')
                echo "Successfully retrieved blob extension key."
                break
            else
                echo "WARNING: Blob extension key not found in system keys. Waiting for function runtime to initialize..."
                if [ $attempt -lt $MAX_RETRIES ]; then
                    echo "Retrying in $RETRY_DELAY seconds..."
                    sleep $RETRY_DELAY
                fi
            fi
        else
            echo "WARNING: Failed to retrieve function app keys: $KEYS_RESULT"
            if [ $attempt -lt $MAX_RETRIES ]; then
                echo "Retrying in $RETRY_DELAY seconds..."
                sleep $RETRY_DELAY
            fi
        fi
    done
    
    if [ -n "$BLOB_EXTENSION_KEY" ]; then
        # Build webhook endpoint URL
        FUNCTION_APP_URL="https://${FUNCTION_APP_NAME}.azurewebsites.net"
        FUNCTION_NAME="start_orchestrator_on_blob"
        WEBHOOK_URL="${FUNCTION_APP_URL}/runtime/webhooks/blobs?functionName=Host.Functions.${FUNCTION_NAME}&code=${BLOB_EXTENSION_KEY}"
        
        echo "Webhook URL: $WEBHOOK_URL"
        
        # Create Event Grid subscription
        SUBSCRIPTION_NAME="${FUNCTION_APP_NAME}-bronze-eg"
        echo "Creating Event Grid subscription: $SUBSCRIPTION_NAME"
        
        SUBSCRIPTION_ID=$(az account show --query id -o tsv)
        SOURCE_RESOURCE_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}"
        
        echo "Source Resource ID: $SOURCE_RESOURCE_ID"
        
        EVENT_SUB_RESULT=$(az eventgrid event-subscription create \
            --name "$SUBSCRIPTION_NAME" \
            --source-resource-id "$SOURCE_RESOURCE_ID" \
            --endpoint-type webhook \
            --endpoint "$WEBHOOK_URL" \
            --included-event-types Microsoft.Storage.BlobCreated \
            --subject-begins-with "/blobServices/default/containers/bronze/blobs/" \
            2>&1)
        
        if [ $? -eq 0 ]; then
            echo "Successfully created Event Grid subscription: $SUBSCRIPTION_NAME"
        else
            if echo "$EVENT_SUB_RESULT" | grep -qE "already exists|Conflict"; then
                echo "Event Grid subscription already exists. Skipping creation."
            else
                echo "WARNING: Failed to create Event Grid subscription: $EVENT_SUB_RESULT"
            fi
        fi
    else
        echo "================================================"
        echo "WARNING: Blob extension key not available!"
        echo "================================================"
        echo "The blob extension key is only generated after the function code is deployed."
        echo "Please wait a few minutes and run this script again, or check the function app status."
        echo "================================================"
        exit 1
    fi
else
    if [ "$IS_FLEX_CONSUMPTION" != true ]; then
        echo "Skipping Event Grid subscription creation (not Flex Consumption plan)."
    else
        echo "Skipping Event Grid subscription creation (function app name not found)."
        echo "Available function app variables: FUNCTION_APP_NAME=$FUNCTION_APP_NAME, PROCESSING_FUNCTION_APP_NAME=$PROCESSING_FUNCTION_APP_NAME"
    fi
fi

echo "Post-deployment script completed."



