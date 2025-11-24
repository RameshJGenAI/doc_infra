Write-Host "Post-provisioning script started."

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

if (-not $env:AZURE_STORAGE_ACCOUNT) {
    Write-Error "AZURE_STORAGE_ACCOUNT environment variable is not set."
    exit 1
}

if (-not $env:RESOURCE_GROUP) {
    Write-Error "RESOURCE_GROUP environment variable is not set."
    exit 1
}

Write-Host "Uploading Blob to Azure Storage Account: $env:AZURE_STORAGE_ACCOUNT"

# Use --auth-mode login since key-based authentication may not be permitted
# This uses the logged-in Azure CLI identity
$useAuthMode = $true
Write-Host "Using Azure CLI authentication (--auth-mode login) for storage operations."

# Function to upload blob with retry
function Upload-Blob {
    param(
        [string]$ContainerName,
        [string]$BlobName,
        [string]$FilePath,
        [bool]$UseAuthMode
    )
    
    $maxRetries = 3
    $retryDelay = 5
    
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-Host "Upload attempt $attempt of $maxRetries for $BlobName..."
        
        if ($UseAuthMode) {
            $uploadResult = az storage blob upload `
                --account-name $env:AZURE_STORAGE_ACCOUNT `
                --container-name $ContainerName `
                --name $BlobName `
                --file $FilePath `
                --auth-mode login `
                2>&1
        } else {
            Write-Error "Connection string authentication not supported. Use --auth-mode login."
            return $false
        }
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully uploaded $BlobName"
            return $true
        } else {
            if ($uploadResult -match "already exists" -or $uploadResult -match "BlobAlreadyExists") {
                Write-Host "File $BlobName already exists. Skipping upload"
                return $true
            } else {
                Write-Warning "Upload attempt $attempt failed: $uploadResult"
                if ($attempt -lt $maxRetries) {
                    Write-Host "Retrying in $retryDelay seconds..."
                    Start-Sleep -Seconds $retryDelay
                }
            }
        }
    }
    return $false
}

# Upload prompts.yaml
if (Test-Path "./data/prompts.yaml") {
    $success = Upload-Blob -ContainerName "prompts" -BlobName "prompts.yaml" -FilePath "./data/prompts.yaml" -UseAuthMode $useAuthMode
    if ($success) {
        Write-Host "Upload of prompts.yaml completed successfully to $env:AZURE_STORAGE_ACCOUNT."
    } else {
        Write-Warning "Failed to upload prompts.yaml after multiple attempts."
    }
} else {
    Write-Warning "File ./data/prompts.yaml not found. Skipping upload."
}

# Upload role_library-3.pdf
if (Test-Path "./data/role_library-3.pdf") {
    $success = Upload-Blob -ContainerName "bronze" -BlobName "role_library-3.pdf" -FilePath "./data/role_library-3.pdf" -UseAuthMode $useAuthMode
    if ($success) {
        Write-Host "Upload of role_library-3.pdf completed successfully to $env:AZURE_STORAGE_ACCOUNT."
    } else {
        Write-Warning "Failed to upload role_library-3.pdf after multiple attempts."
    }
} else {
    Write-Warning "File ./data/role_library-3.pdf not found. Skipping upload."
}

# Run Cosmos upload if script exists
if (Test-Path "./uploadCosmos.py") {
    python uploadCosmos.py
} else {
    Write-Host "uploadCosmos.py not found. Skipping Cosmos upload."
}

# Event Grid subscription creation has been moved to postdeploy.ps1
# The blob extension key is only available after the function code is deployed
Write-Host "Event Grid subscription will be created after function deployment (in postdeploy script)."