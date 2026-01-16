#!/usr/bin/env pwsh

$BASE_URL = "http://localhost:5001/api/operationmanagement"
$LONG_TIMEOUT = 80

function Test-Endpoint {
    param(
        [string]$Step,
        [string]$Method,
        [string]$Endpoint,
        [int]$WaitSeconds = 0
    )
    
    Write-Host "`n=== $Step ===" -ForegroundColor Cyan
    
    try {
        $url = "$BASE_URL$Endpoint"
        Write-Host "URL: $url" -ForegroundColor Gray
        
        $splat = @{
            Uri = $url
            Method = $Method
            UseBasicParsing = $true
            TimeoutSec = $LONG_TIMEOUT
            ErrorAction = 'Continue'
        }
        
        $response = Invoke-WebRequest @splat 2>&1
        
        if ($response.Content) {
            $response.Content | ConvertFrom-Json | ConvertTo-Json -Depth 3
        }
        
        if ($WaitSeconds -gt 0) {
            Write-Host "Waiting ${WaitSeconds}s..." -ForegroundColor Gray
            Start-Sleep -Seconds $WaitSeconds
        }
    } catch {
        Write-Host "Error: $_" -ForegroundColor Red
    }
}

Write-Host "Starting test sequence..." -ForegroundColor Green

# Step 1: Promote node1
Test-Endpoint -Step "Step 1: Promote node1 to primary" -Method POST -Endpoint "/promote/node1" -Wait 10

# Step 2: Demote all
Test-Endpoint -Step "Step 2: Demote all" -Method POST -Endpoint "/demote-all" -Wait 15

# Step 3: Promote node3
Test-Endpoint -Step "Step 3: Promote node3 to primary" -Method POST -Endpoint "/promote/node3" -Wait 10

# Step 4: Demote all
Test-Endpoint -Step "Step 4: Demote all" -Method POST -Endpoint "/demote-all" -Wait 15

# Step 5: Promote node2
Test-Endpoint -Step "Step 5: Promote node2 to primary" -Method POST -Endpoint "/promote/node2" -Wait 10

# Final status
Test-Endpoint -Step "Final Status" -Method GET -Endpoint "/status"

Write-Host "`n✓ Test sequence completed" -ForegroundColor Green
