#!/usr/bin/env powershell
# Simple 30-minute PostgreSQL HA Failover Test

$TestDuration = 1800  # 30 minutes
$FailoverInterval = 300  # 5 minutes
$LogDir = "test-logs"

if (!(Test-Path $LogDir)) { 
    New-Item -ItemType Directory -Path $LogDir | Out-Null 
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "$LogDir/test-$timestamp.log"
$resultsFile = "$LogDir/results-$timestamp.log"

Write-Host "==== PostgreSQL HA 30-Minute Failover Test ====" -ForegroundColor Cyan
Write-Host "Duration: 30 minutes" -ForegroundColor Cyan
Write-Host "Failovers: Every 5 minutes" -ForegroundColor Cyan
Write-Host "Log file: $logFile" -ForegroundColor Cyan
Write-Host ""

# Test if we can connect to primary
Write-Host "Checking primary connection..." -ForegroundColor Yellow
$testConn = docker exec pg-node-1 pg_isready -U appuser -d appdb 2>$null
if ($testConn -notlike "*accepting*") {
    Write-Host "ERROR: Cannot connect to primary!" -ForegroundColor Red
    exit 1
}
Write-Host "Primary is ready!" -ForegroundColor Green
Write-Host ""

# Clear test data and create fresh table
Write-Host "Preparing test environment..." -ForegroundColor Yellow
docker exec pg-node-1 psql -U appuser -d appdb -c "DROP TABLE IF EXISTS test_data; CREATE TABLE test_data (id SERIAL PRIMARY KEY, value TEXT, ts TIMESTAMP DEFAULT NOW());" 2>$null | Out-Null
Write-Host "Test tables created!" -ForegroundColor Green
Write-Host ""

# Start test
$testStart = Get-Date
$lastFailover = 0

Write-Host "Starting test..." -ForegroundColor Cyan

# Background write job
$writeJob = Start-Job -ScriptBlock {
    $counter = 0
    while ($true) {
        $counter++
        for ($i = 0; $i -lt 5; $i++) {
            docker exec pg-node-1 psql -U appuser -d appdb -c "INSERT INTO test_data (value) VALUES ('batch_$counter-$i');" 2>$null
        }
        Start-Sleep -Milliseconds 500
    }
}

Write-Host "Write workload started" -ForegroundColor Green
Write-Host ""

# Main loop
$lastValidation = 0
while ($true) {
    $elapsed = [int]((Get-Date) - $testStart).TotalSeconds
    
    if ($elapsed -ge $TestDuration) {
        break
    }
    
    # Failover every 5 minutes
    if ($elapsed -ge ($lastFailover + $FailoverInterval)) {
        $lastFailover = $elapsed
        $failoverNum = [int]($elapsed / $FailoverInterval) + 1
        $nextNode = ($failoverNum % 6) + 1
        $nextPrimary = "pg-node-$nextNode"
        
        Write-Host "[$elapsed/$TestDuration] Promoting $nextPrimary to primary..." -ForegroundColor Yellow
        docker exec $nextPrimary pg_ctl promote -D /var/lib/postgresql/data 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        Write-Host "[$elapsed/$TestDuration] Failover complete!" -ForegroundColor Green
    }
    
    # Validate every 60 seconds
    if ($elapsed -ge ($lastValidation + 60)) {
        $lastValidation = $elapsed
        
        $row1 = docker exec pg-node-1 psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        $row2 = docker exec pg-node-2 psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        $row3 = docker exec pg-node-3 psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        
        $msg = "[$elapsed/$TestDuration] Validation: pg-node-1=$row1 pg-node-2=$row2 pg-node-3=$row3"
        Write-Host $msg -ForegroundColor Cyan
        Add-Content -Path $resultsFile -Value $msg
    }
    
    # Progress
    $remaining = $TestDuration - $elapsed
    $elapsedMin = [int]$elapsed / 60
    $elapsedSec = $elapsed % 60
    $remainingMin = [int]$remaining / 60
    $remainingSec = $remaining % 60
    
    Write-Host -NoNewline "`rElapsed: $elapsedMin`:$($elapsedSec.ToString('00')) | Remaining: $remainingMin`:$($remainingSec.ToString('00'))   "
    
    Start-Sleep -Seconds 1
}

# Cleanup
Write-Host ""
Write-Host ""
Write-Host "Stopping write workload..." -ForegroundColor Yellow
$writeJob | Stop-Job | Remove-Job
Write-Host "Write workload stopped!" -ForegroundColor Green

# Final validation
Write-Host ""
Write-Host "==== FINAL VALIDATION ====" -ForegroundColor Cyan

$nodes = 1..6 | ForEach-Object { "pg-node-$_" }
foreach ($node in $nodes) {
    $count = docker exec $node psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
    Write-Host "${node}: $count rows" -ForegroundColor Yellow
    Add-Content -Path $resultsFile -Value "FINAL: ${node} = $count rows"
}

Write-Host ""
Write-Host "Test completed!" -ForegroundColor Green
Write-Host "Results saved to: $resultsFile" -ForegroundColor Green
Write-Host ""
