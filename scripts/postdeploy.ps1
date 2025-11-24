Write-Host "Post-deployment script started."

# Load azd environment values (emulates: eval $(azd env get-values))
azd env get-values | ForEach-Object {
    if ($_ -match '^(?<key>[^=]+)=(?<val>.*)$') {
        $k = $matches.key.Trim()
        $v = $matches.val

        # Remove exactly one outer pair of double quotes if present
        if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) {
            $v = $v.Substring(1, $v.Length - 2)
            # Unescape any embedded \" (azd usually doesn't emit these, but safe)
            $v = $v -replace '\\"','"'
        }

        [Environment]::SetEnvironmentVariable($k, $v)
        Set-Variable -Name $k -Value $v -Scope Script -Force
    }
}

Write-Host "Current Path: $(Get-Location)"

# Check for function app name (could be FUNCTION_APP_NAME or PROCESSING_FUNCTION_APP_NAME)
$functionAppName = $env:FUNCTION_APP_NAME
if (-not $functionAppName) {
    $functionAppName = $env:PROCESSING_FUNCTION_APP_NAME
}

# Check if Flex Consumption is enabled from environment variable (set by azd from Bicep output)
$isFlexConsumption = $false
if ($env:FUNCTION_APP_PLAN_TYPE) {
    Write-Host "FUNCTION_APP_PLAN_TYPE from environment: $env:FUNCTION_APP_PLAN_TYPE"
    if ($env:FUNCTION_APP_PLAN_TYPE -eq "FlexConsumption") {
        $isFlexConsumption = $true
        Write-Host "Flex Consumption plan detected from environment variable."
    }
} elseif ($functionAppName) {
    # Fallback: Try to determine from function app configuration
    Write-Host "FUNCTION_APP_PLAN_TYPE not in environment. Checking function app app settings..."
    $planType = az functionapp config appsettings list `
        --name $functionAppName `
        --resource-group $env:RESOURCE_GROUP `
        --query "[?name=='FUNCTION_APP_PLAN_TYPE'].value" `
        -o tsv `
        2>&1
    
    if ($LASTEXITCODE -eq 0 -and $planType -and $planType.Trim() -eq "FlexConsumption") {
        $isFlexConsumption = $true
        Write-Host "Flex Consumption plan detected from function app app settings."
    }
} else {
    Write-Host "Cannot determine plan type: function app name not found."
}

if ($isFlexConsumption -and $functionAppName) {
    Write-Host "Creating Event Grid subscription for Flex Consumption blob triggers..."
    Write-Host "Function App: $functionAppName"
    
    $resourceGroup = $env:RESOURCE_GROUP
    $storageAccountName = $env:AZURE_STORAGE_ACCOUNT
    
    if (-not $resourceGroup) {
        Write-Warning "RESOURCE_GROUP environment variable is not set. Skipping Event Grid subscription creation."
        exit 0
    }
    
    if (-not $storageAccountName) {
        Write-Warning "AZURE_STORAGE_ACCOUNT environment variable is not set. Skipping Event Grid subscription creation."
        exit 0
    }
    
    # Get blob extension key with retry logic
    # Note: The blob extension key is only available after the function app is deployed with blob trigger functions
    Write-Host "Retrieving blob extension key for function app: $functionAppName"
    $maxRetries = 5
    $retryDelay = 10
    $blobExtensionKey = $null
    
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Host "Attempt $attempt of $maxRetries to retrieve blob extension key..."
        $keysResult = az functionapp keys list `
            --name $functionAppName `
            --resource-group $resourceGroup `
            -o json `
            2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $keysJson = $keysResult | ConvertFrom-Json
            if ($keysJson.systemKeys -and $keysJson.systemKeys.blobs_extension) {
                $blobExtensionKey = $keysJson.systemKeys.blobs_extension.Trim()
                Write-Host "Successfully retrieved blob extension key."
                break
            } else {
                Write-Warning "Blob extension key not found in system keys. Waiting for function runtime to initialize..."
                if ($attempt -lt $maxRetries) {
                    Write-Host "Retrying in $retryDelay seconds..."
                    Start-Sleep -Seconds $retryDelay
                }
            }
        } else {
            Write-Warning "Failed to retrieve function app keys: $keysResult"
            if ($attempt -lt $maxRetries) {
                Write-Host "Retrying in $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
        }
    }
    
    if ($blobExtensionKey) {
        # Build webhook endpoint URL
        $functionAppUrl = "https://${functionAppName}.azurewebsites.net"
        $functionName = "start_orchestrator_on_blob"
        $webhookUrl = "${functionAppUrl}/runtime/webhooks/blobs?functionName=Host.Functions.${functionName}&code=${blobExtensionKey}"
        
        Write-Host "Webhook URL: $webhookUrl"
        
        # Create Event Grid subscription
        $subscriptionName = "${functionAppName}-bronze-eg"
        Write-Host "Creating Event Grid subscription: $subscriptionName"
        
        $subscriptionId = az account show --query id -o tsv
        $sourceResourceId = "/subscriptions/${subscriptionId}/resourceGroups/${resourceGroup}/providers/Microsoft.Storage/storageAccounts/${storageAccountName}"
        
        Write-Host "Source Resource ID: $sourceResourceId"
        
        # Wait a bit for function app to initialize blob extension webhook
        Write-Host "Waiting for function app blob extension to initialize..."
        Start-Sleep -Seconds 15
        
        # Check if subscription already exists
        $existingSub = az eventgrid event-subscription show `
            --name $subscriptionName `
            --source-resource-id $sourceResourceId `
            2>&1
        
        $subscriptionExists = ($LASTEXITCODE -eq 0)
        
        if ($subscriptionExists) {
            Write-Host "Event Grid subscription already exists. Deleting and recreating with correct filters..."
            
            # Delete the existing subscription first
            $deleteResult = az eventgrid event-subscription delete `
                --name $subscriptionName `
                --source-resource-id $sourceResourceId `
                2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Deleted existing subscription. Will recreate with correct filters."
            } else {
                Write-Warning "Failed to delete existing subscription: $deleteResult"
                Write-Warning "Will attempt to create anyway (may fail if it still exists)"
            }
            
            # Wait a moment for deletion to complete
            Start-Sleep -Seconds 5
        }
        
        # Create or recreate the subscription
        if ($true) {
            # Create Event Grid subscription with retry logic for validation issues
            $maxSubscriptionRetries = 5
            $subscriptionRetryDelay = 20
            $subscriptionCreated = $false
            
            for ($subAttempt = 1; $subAttempt -le $maxSubscriptionRetries; $subAttempt++) {
                Write-Host "Creating Event Grid subscription (attempt $subAttempt of $maxSubscriptionRetries)..."
                
                $eventSubResult = az eventgrid event-subscription create `
                    --name $subscriptionName `
                    --source-resource-id $sourceResourceId `
                    --endpoint-type webhook `
                    --endpoint $webhookUrl `
                    --included-event-types Microsoft.Storage.BlobCreated `
                    --subject-begins-with "/blobServices/default/containers/bronze/blobs/" `
                    --event-delivery-schema EventGridSchema `
                    2>&1
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "Successfully created Event Grid subscription: $subscriptionName"
                    $subscriptionCreated = $true
                    break
                } else {
                    if ($eventSubResult -match "already exists" -or $eventSubResult -match "Conflict") {
                        Write-Host "Event Grid subscription already exists. Updating it..."
                        # Try to update instead
                        $updateResult = az eventgrid event-subscription update `
                            --name $subscriptionName `
                            --source-resource-id $sourceResourceId `
                            --endpoint-type webhook `
                            --endpoint $webhookUrl `
                            --included-event-types Microsoft.Storage.BlobCreated `
                            --subject-begins-with "/blobServices/default/containers/bronze/blobs/" `
                            --event-delivery-schema EventGridSchema `
                            2>&1
                        if ($LASTEXITCODE -eq 0) {
                            Write-Host "Successfully updated Event Grid subscription: $subscriptionName"
                            $subscriptionCreated = $true
                            break
                        }
                    } elseif ($eventSubResult -match "validation" -or $eventSubResult -match "handshake") {
                        Write-Warning "Webhook validation failed (attempt $subAttempt/$maxSubscriptionRetries)"
                        Write-Warning "This is common - the blob extension webhook may need more time to initialize."
                        if ($subAttempt -lt $maxSubscriptionRetries) {
                            Write-Host "Waiting $subscriptionRetryDelay seconds before retry..."
                            Start-Sleep -Seconds $subscriptionRetryDelay
                        }
                    } else {
                        Write-Warning "Failed to create Event Grid subscription: $eventSubResult"
                        Write-Warning "Exit code: $LASTEXITCODE"
                        break
                    }
                }
            }
        }
        
        if (-not $subscriptionCreated) {
            Write-Warning ""
            Write-Warning "================================================"
            Write-Warning "Could not create Event Grid subscription automatically!"
            Write-Warning "The webhook validation handshake is failing."
            Write-Warning "================================================"
            Write-Warning ""
            Write-Warning "OPTION 1: Create manually via Azure Portal (Recommended)"
            Write-Warning "1. Go to: https://portal.azure.com"
            Write-Warning "2. Navigate to Storage Account: $storageAccountName"
            Write-Warning "3. Click 'Events' in the left menu"
            Write-Warning "4. Click '+ Event Subscription'"
            Write-Warning "5. Details tab:"
            Write-Warning "   - Name: $subscriptionName"
            Write-Warning "   - Event Schema: Event Grid Schema"
            Write-Warning "6. Filters tab:"
            Write-Warning "   - Subject Begins With: /blobServices/default/containers/bronze/blobs/"
            Write-Warning "   - Event Types: Microsoft.Storage.BlobCreated"
            Write-Warning "7. Endpoints tab:"
            Write-Warning "   - Endpoint Type: Web Hook"
            Write-Warning "   - Subscriber Endpoint: $webhookUrl"
            Write-Warning "8. Click 'Create'"
            Write-Warning ""
            Write-Warning "OPTION 2: Wait a few minutes and re-run this script"
            Write-Warning "The blob extension webhook may initialize after a few minutes."
            Write-Warning ""
            Write-Warning "OPTION 3: Verify function app is running and blob trigger is deployed"
            Write-Warning "Check that the function 'start_orchestrator_on_blob' exists and is enabled."
            Write-Warning "================================================"
            Write-Warning ""
        }
    } else {
        Write-Warning "================================================"
        Write-Warning "Blob extension key not available!"
        Write-Warning "================================================"
        Write-Warning "The blob extension key is only generated after the function code is deployed."
        Write-Warning "Please wait a few minutes and run this script again, or check the function app status."
        Write-Warning "================================================"
        exit 1
    }
} else {
    if (-not $isFlexConsumption) {
        Write-Host "Skipping Event Grid subscription creation (not Flex Consumption plan)."
    } else {
        Write-Host "Skipping Event Grid subscription creation (function app name not found)."
        Write-Host "Available function app variables: FUNCTION_APP_NAME=$env:FUNCTION_APP_NAME, PROCESSING_FUNCTION_APP_NAME=$env:PROCESSING_FUNCTION_APP_NAME"
    }
}

Write-Host "Post-deployment script completed."


