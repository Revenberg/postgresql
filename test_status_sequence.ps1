#!/usr/bin/env pwsh

$BASE_URL = "http://localhost:5001/api/operationmanagement"

function Get-ClusterStatus {
    try {
        $response = Invoke-WebRequest -Uri "$BASE_URL/status" -Method GET -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $data = $response.Content | ConvertFrom-Json
        
        $primary = "NONE"
        foreach ($node in @('node1', 'node2', 'node3')) {
            if ($data.nodes.$node.is_primary -eq $true) {
                $primary = $node.ToUpper()
            }
        }
        
        return $primary
    } catch {
        return "ERROR"
    }
}

function Set-NodePrimary {
    param([string]$NodeName)
    
    Write-Host "`n>>> Promoting $NodeName to PRIMARY..." -ForegroundColor Cyan
    try {
        $response = Invoke-WebRequest -Uri "$BASE_URL/promote/$NodeName" -Method POST -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $data = $response.Content | ConvertFrom-Json
        Write-Host "    ✓ $($data.message)" -ForegroundColor Green
    } catch {
        Write-Host "    ✗ Error: $_" -ForegroundColor Red
    }
    
    Write-Host "    Waiting 12 seconds for stabilization..." -ForegroundColor Gray
    Start-Sleep -Seconds 12
    
    $status = Get-ClusterStatus
    Write-Host "    Current PRIMARY: $status" -ForegroundColor Yellow
    return $status
}

function Demote-All {
    Write-Host "`n>>> Demoting ALL nodes to STANDBY..." -ForegroundColor Magenta
    try {
        $response = Invoke-WebRequest -Uri "$BASE_URL/demote-all" -Method POST -UseBasicParsing -TimeoutSec 120 -ErrorAction Continue
        Write-Host "    ✓ Demote initiated" -ForegroundColor Green
    } catch {
        Write-Host "    ✗ Error (may be timeout, which is normal): $($_.Exception.Response.StatusCode)" -ForegroundColor Yellow
    }
    
    Write-Host "    Waiting 15 seconds for stabilization..." -ForegroundColor Gray
    Start-Sleep -Seconds 15
    
    $status = Get-ClusterStatus
    Write-Host "    Current PRIMARY: $status (should be NONE)" -ForegroundColor Yellow
    return $status
}

# Test sequence
Write-Host "========================================" -ForegroundColor White
Write-Host "PostgreSQL Cluster Status Test Sequence" -ForegroundColor White
Write-Host "========================================" -ForegroundColor White

# Step 1: Set node1 primary
$result1 = Set-NodePrimary "node1"
if ($result1 -ne "NODE1") {
    Write-Host "    ⚠ WARNING: Expected NODE1 but got $result1" -ForegroundColor Yellow
}

# Step 2: Demote all
$result2 = Demote-All
if ($result2 -ne "NONE") {
    Write-Host "    ⚠ WARNING: Expected NONE but got $result2" -ForegroundColor Yellow
}

# Step 3: Set node3 primary
$result3 = Set-NodePrimary "node3"
if ($result3 -ne "NODE3") {
    Write-Host "    ⚠ WARNING: Expected NODE3 but got $result3" -ForegroundColor Yellow
}

# Step 4: Set node2 primary (should demote node3 first automatically)
$result4 = Set-NodePrimary "node2"
if ($result4 -ne "NODE2") {
    Write-Host "    ⚠ WARNING: Expected NODE2 but got $result4" -ForegroundColor Yellow
}

# Step 5: Set node3 primary (should demote node2 first automatically)
$result5 = Set-NodePrimary "node3"
if ($result5 -ne "NODE3") {
    Write-Host "    ⚠ WARNING: Expected NODE3 but got $result5" -ForegroundColor Yellow
}

# Final status
Write-Host "`n>>> FINAL CLUSTER STATUS" -ForegroundColor Green
try {
    $response = Invoke-WebRequest -Uri "$BASE_URL/status" -Method GET -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    $response.Content | ConvertFrom-Json | ConvertTo-Json
} catch {
    Write-Host "Error getting final status: $_" -ForegroundColor Red
}

Write-Host "`n========================================" -ForegroundColor White
Write-Host "✓ Test Sequence Complete" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor White
