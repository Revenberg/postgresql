#!/usr/bin/env powershell
# Test new host management endpoints

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "Testing Host Management Endpoints"
Write-Host "======================================================================" -ForegroundColor Cyan

# Test 1: Add a replica host
Write-Host "`n[TEST 1] Adding replica-3 as a replica host..." -ForegroundColor Yellow
$headers = @{'Content-Type' = 'application/json'}
$body = '{"name":"replica-3","ip":"172.18.0.8","port":5438,"type":"replica"}'
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/hosts" `
        -Method POST -Headers $headers -Body $body -UseBasicParsing -TimeoutSec 10
    Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Green
    $data = $response.Content | ConvertFrom-Json
    Write-Host "  Message: $($data.message)"
    Write-Host "  Host Details: $($data.host | ConvertTo-Json -Compress)"
} catch {
    Write-Host "  Error: $($_)" -ForegroundColor Red
}

# Test 2: Add a backup host
Write-Host "`n[TEST 2] Adding node4 as a backup host..." -ForegroundColor Yellow
$body = '{"name":"node4","ip":"172.18.0.7","port":5437,"type":"backup"}'
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/hosts" `
        -Method POST -Headers $headers -Body $body -UseBasicParsing -TimeoutSec 10
    Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Green
    $data = $response.Content | ConvertFrom-Json
    Write-Host "  Message: $($data.message)"
} catch {
    Write-Host "  Error: $($_)" -ForegroundColor Red
}

# Test 3: Try to add duplicate (should fail)
Write-Host "`n[TEST 3] Attempting to add duplicate replica-3 (should fail)..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/hosts" `
        -Method POST -Headers $headers -Body '{"name":"replica-3","ip":"172.18.0.9","port":5439,"type":"replica"}' `
        -UseBasicParsing -TimeoutSec 10
    Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Red
} catch {
    $error_data = $_.Exception.Response
    Write-Host "  Status: $($error_data.StatusCode)" -ForegroundColor Green
    Write-Host "  Error caught as expected"
}

# Test 4: Check overview to see new nodes
Write-Host "`n[TEST 4] Checking cluster overview for new nodes..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/overview" `
        -UseBasicParsing -TimeoutSec 10
    $data = $response.Content | ConvertFrom-Json
    Write-Host "  Total nodes: $($data.nodes.Count)" -ForegroundColor Green
    Write-Host "  Nodes:"
    foreach ($node in $data.nodes) {
        $nodeType = $node.type.ToUpper()
        $role = if($node.is_primary) {"PRIMARY"} else {"STANDBY"}
        Write-Host "    - $($node.name) [$nodeType] ($role)"
    }
} catch {
    Write-Host "  Error: $($_)" -ForegroundColor Red
}

# Test 5: Try to promote a replica (should fail)
Write-Host "`n[TEST 5] Attempting to promote replica-1 to primary (should fail)..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/replica-1" `
        -Method POST -UseBasicParsing -TimeoutSec 10
    Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Red
    Write-Host "  Promotion succeeded (ERROR - should have failed)" -ForegroundColor Red
} catch {
    $status = $_.Exception.Response.StatusCode
    if ($status -eq 400) {
        Write-Host "  Status: $status" -ForegroundColor Green
        Write-Host "  Replica promotion correctly blocked" -ForegroundColor Green
    } else {
        Write-Host "  Status: $status (unexpected)" -ForegroundColor Yellow
    }
}

# Test 6: Delete a backup node
Write-Host "`n[TEST 6] Deleting node4 backup host..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/hosts/node4" `
        -Method DELETE -UseBasicParsing -TimeoutSec 10
    Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Green
    $data = $response.Content | ConvertFrom-Json
    Write-Host "  Message: $($data.message)"
    Write-Host "  Deleted: $($data.deleted_host.name) ($($data.deleted_host.ip))"
} catch {
    Write-Host "  Error: $($_)" -ForegroundColor Red
}

# Test 7: Delete by IP address
Write-Host "`n[TEST 7] Deleting replica-3 by IP address (172.18.0.8)..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/hosts/172.18.0.8" `
        -Method DELETE -UseBasicParsing -TimeoutSec 10
    Write-Host "  Status: $($response.StatusCode)" -ForegroundColor Green
    $data = $response.Content | ConvertFrom-Json
    Write-Host "  Message: $($data.message)"
} catch {
    Write-Host "  Error: $($_)" -ForegroundColor Red
}

# Test 8: Final overview check
Write-Host "`n[TEST 8] Final cluster overview..." -ForegroundColor Yellow
try {
    $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/overview" `
        -UseBasicParsing -TimeoutSec 10
    $data = $response.Content | ConvertFrom-Json
    Write-Host "  Nodes remaining: $($data.nodes.Count)" -ForegroundColor Green
    foreach ($node in $data.nodes) {
        $nodeType = if($node.is_replica) {"REPLICA"} else {"BACKUP"}
        Write-Host "    - $($node.name) ($nodeType)"
    }
} catch {
    Write-Host "  Error: $($_)" -ForegroundColor Red
}

Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "Tests Complete"
Write-Host "======================================================================" -ForegroundColor Cyan
