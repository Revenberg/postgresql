#!/usr/bin/env powershell
Set-Location "C:\Users\reven\docker\postgreSQL"

function Test-Promote {
    param($node, $step, $total)
    
    Write-Host "`n[$step/$total] PROMOTE $node" -ForegroundColor Cyan
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/$node" -Method POST -UseBasicParsing -TimeoutSec 180 -ErrorAction Continue
        Write-Host "Response: $($response.StatusCode)"
    } catch {
        Write-Host "Response: Timeout/504 (operation continues)"
    }
    
    Write-Host "Waiting 30 seconds..." -ForegroundColor Gray
    Start-Sleep -Seconds 30
    
    try {
        $r = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status" -UseBasicParsing -TimeoutSec 30
        $data = $r.Content | ConvertFrom-Json
        $n1 = $data.nodes.node1.is_primary
        $n2 = $data.nodes.node2.is_primary
        $n3 = $data.nodes.node3.is_primary
        $primary = if ($n1) { "NODE1" } elseif ($n2) { "NODE2" } elseif ($n3) { "NODE3" } else { "NONE" }
        Write-Host "Status: n1=$n1, n2=$n2, n3=$n3 => Primary: $primary" -ForegroundColor Yellow
    } catch {
        Write-Host "Status: FAILED to check" -ForegroundColor Red
    }
}

Write-Host "=== PostgreSQL Cluster Test ===" -ForegroundColor Green

Test-Promote "node1" 1 5
Test-Promote "node3" 2 5
Test-Promote "node2" 3 5
Test-Promote "node3" 4 5

Write-Host "`n=== Test Complete ===" -ForegroundColor Green
