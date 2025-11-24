# How to Verify Blob Trigger in Azure Portal

## Step 1: Upload a File to Bronze Container

1. Go to **Azure Portal** → **Storage accounts**
2. Click on your storage account: `stexjgsnv4h3idc`
3. In the left menu, click **Containers**
4. Click on the **bronze** container
5. Click **Upload** button at the top
6. Select a test file (e.g., a PDF or text file)
7. Click **Upload**

## Step 2: Verify Event Grid Subscription

1. Go to **Storage accounts** → `stexjgsnv4h3idc`
2. In the left menu, click **Events**
3. You should see the subscription: `func-processing-exjgsnv4h3idc-bronze-eg`
4. Click on it to view details:
   - **Status** should be **Enabled**
   - **Endpoint type** should be **Web Hook**
   - **Event types** should include **Blob Created**
   - **Subject filter** should be `/blobServices/default/containers/bronze/blobs/`

## Step 3: Check Event Grid Metrics

1. Go to **Event Grid subscriptions** → `func-processing-exjgsnv4h3idc-bronze-eg`
2. Click **Metrics** in the left menu
3. Check:
   - **Published events** - Should show events when you upload files
   - **Matched events** - Events that match the filter
   - **Delivered events** - Successfully delivered to your function
   - **Delivery failed events** - Any failures (should be 0)

## Step 4: Check Function App Logs

### Option A: Function Monitor Tab
1. Go to **Function App** → `func-processing-exjgsnv4h3idc`
2. Click **Functions** in the left menu
3. Click on `start_orchestrator_on_blob`
4. Click **Monitor** tab
5. You should see:
   - Recent invocations
   - Execution time
   - Status (Success/Failed)
   - Click on any invocation to see detailed logs

### Option B: Application Insights Logs
1. Go to **Function App** → `func-processing-exjgsnv4h3idc`
2. Click **Monitoring** → **Logs** (or **Application Insights**)
3. Run this query:
   ```kusto
   traces
   | where message contains "start_orchestrator_on_blob" or message contains "Blob Received"
   | order by timestamp desc
   | take 50
   ```

### Option C: Log Stream (Real-time)
1. Go to **Function App** → `func-processing-exjgsnv4h3idc`
2. Click **Monitoring** → **Log stream**
3. Watch logs in real-time as events occur

## Step 5: Check Function Execution Details

1. Go to **Function App** → `func-processing-exjgsnv4h3idc`
2. Click **Functions** → `start_orchestrator_on_blob`
3. Click **Code + Test**
4. Click **Test/Run** tab
5. View recent invocations and their execution logs

## Troubleshooting

### If trigger doesn't fire:

1. **Check Event Grid subscription status:**
   - Storage account → Events → Verify subscription is **Enabled**

2. **Check function app status:**
   - Function App → Overview → Verify **Status** is **Running**

3. **Check Event Grid delivery:**
   - Event Grid subscription → Metrics → Check for delivery failures

4. **Check function logs for errors:**
   - Function App → Functions → `start_orchestrator_on_blob` → Monitor
   - Look for failed executions and error messages

5. **Verify webhook endpoint:**
   - Event Grid subscription → Check if endpoint URL is correct
   - Verify blob extension key is valid

6. **Check blob path:**
   - Ensure file is uploaded to `bronze` container (not a subfolder unless configured)

## Expected Behavior

When you upload a file to the bronze container:
1. Event Grid detects the blob creation event
2. Event Grid sends event to function webhook endpoint
3. Function `start_orchestrator_on_blob` is triggered
4. Function logs show: "Blob Received: ..."
5. Orchestration starts for the blob processing



