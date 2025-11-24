targetScope = 'resourceGroup'

@description('Name of the event subscription.')
param name string

@description('Name of the storage account to subscribe to.')
param storageAccountName string

@description('Function app URL (e.g., https://func-app.azurewebsites.net).')
param functionAppUrl string

@description('Function name (e.g., start_orchestrator_on_blob).')
param functionName string

@description('Blob extension access key for webhook authentication.')
param blobExtensionKey string

@description('Prefix filter for blob events.')
param subjectBeginsWith string = '/blobServices/default/containers/bronze/blobs/'

@description('Maximum number of events per batch.')
param maxEventsPerBatch int = 1

@description('Preferred batch size in KB.')
param preferredBatchSizeInKilobytes int = 64

@description('Maximum delivery attempts for each event.')
param maxDeliveryAttempts int = 30

@description('Event TTL in minutes.')
param eventTimeToLiveInMinutes int = 1440

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

// Build the webhook endpoint URL for blob trigger with EventGrid source
// Format: https://{functionappname}.azurewebsites.net/runtime/webhooks/blobs?functionName=Host.Functions.{functionname}&code={blobs_extension_key}
var webhookEndpoint = '${functionAppUrl}/runtime/webhooks/blobs?functionName=Host.Functions.${functionName}&code=${blobExtensionKey}'

resource eventSubscription 'Microsoft.EventGrid/eventSubscriptions@2023-06-01-preview' = {
  name: name
  scope: storageAccount
  properties: {
    destination: {
      endpointType: 'WebHook'
      properties: {
        endpointUrl: webhookEndpoint
        maxEventsPerBatch: maxEventsPerBatch
        preferredBatchSizeInKilobytes: preferredBatchSizeInKilobytes
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: subjectBeginsWith
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: maxDeliveryAttempts
      eventTimeToLiveInMinutes: eventTimeToLiveInMinutes
    }
  }
}


