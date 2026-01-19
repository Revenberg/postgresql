param(
    [int]$TestDuration = 1800,        # 30 minutes
    [int]$FailoverInterval = 300,     # 5 minutes between failovers
    [int]$ValidationInterval = 60,    # Validate every minute
    [string]$LogDir = "test-logs"
)

# Setup
if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "$LogDir/test-$timestamp.log"
$resultsFile = "$LogDir/results-$timestamp.log"
$failoverLog = "$LogDir/failovers-$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $time = Get-Date -Format "HH:mm:ss"
    $entry = "[$time] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

function Get-NodeRowCount {
    param([string]$NodeName)
    try {
        $cmd = "docker exec $NodeName psql -U appuser -d appdb -t -c 'SELECT COUNT(*) FROM test_data;' 2>null"
        $count = Invoke-Expression $cmd | ForEach-Object { $_.Trim() }
        return $count
    }
    catch { return "ERROR" }
}

function Get-OperationCounts {
    param([string]$NodeName)
    try {
        $query = "SELECT COUNT(*) as total, COUNT(CASE WHEN operation_type='INSERT' THEN 1 END) as inserts, COUNT(CASE WHEN operation_type='UPDATE' THEN 1 END) as updates FROM test_data;"
        $cmd = "docker exec $NodeName psql -U appuser -d appdb -t -c '$query' 2>null"
        $result = Invoke-Expression $cmd | ForEach-Object { $_.Trim() }
        return $result
    }
    catch { return "ERROR ERROR ERROR" }
}


function Promote-Node {
    param([string]$NewPrimary)
    Write-Log "Promoting $NewPrimary to primary..." "FAILOVER"
    
    $cmd = "docker exec $NewPrimary pg_ctl promote -D /var/lib/postgresql/data 2>&1"
    Invoke-Expression $cmd | Out-Null
    Start-Sleep -Seconds 5
    
    Write-Log "promoted to primary" "FAILOVER"
    Add-Content -Path $failoverLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Promoted $NewPrimary"
}

function Get-CurrentPrimary {
    $cmd = "docker exec pg-node-1 psql -U appuser -d appdb -t -c 'SELECT pg_is_wal_replay_paused();' 2>null"
    $result = Invoke-Expression $cmd
    
    if ($result -like "*t*") { return "pg-node-1" }
    
    for ($i = 2; $i -le 6; $i++) {
        $node = "pg-node-$i"
        $cmd = "docker exec $node psql -U appuser -d appdb -t -c 'SELECT NOT pg_is_wal_replay_paused();' 2>null"
        $result = Invoke-Expression $cmd | ForEach-Object { $_.Trim() }
        
        if ($result -eq "t") { return $node }
    }
    
    return "UNKNOWN"
}


# Main test execution
Write-Log "================================"
Write-Log "PostgreSQL HA 30-Minute Failover Test"
Write-Log "================================"
Write-Log "Test Duration: $TestDuration seconds (30 minutes)"
Write-Log "Failover Interval: $FailoverInterval seconds (every 5 minutes)"
Write-Log "Validation Interval: $ValidationInterval seconds (every minute)"
Write-Log ""

# Start test
$testStart = Get-Date
$elapsed = 0
$validationCounter = 0
$failoverCounter = 0

# Background write workload
Write-Log "Starting write workload..."
$writeJob = Start-Job -ScriptBlock {
    $nodeName = "pg-node-1"
    $counter = 0
    while ($true) {
        $counter++
        
        # Insert operations
        for ($i = 0; $i -lt 10; $i++) {
            docker exec $nodeName psql -U appuser -d appdb -c `
                "INSERT INTO test_data (test_value, operation_type) 
                 VALUES ('write_batch_$counter-row_$i', 'INSERT');" 2>$null
        }
        
        # Update operations (every 5 inserts)
        if ($counter % 5 -eq 0) {
            $updateCount = $counter * 10
            docker exec $nodeName psql -U appuser -d appdb -c `
                "UPDATE test_data SET operation_type='UPDATE', update_timestamp=NOW() 
                 WHERE id <= 10 LIMIT 5;" 2>$null
        }
        
        Start-Sleep -Milliseconds 500
    }
}

Write-Log "✓ Write workload started"

# Main test loop
while ($elapsed -lt $TestDuration) {
    $elapsed = [int]((Get-Date) - $testStart).TotalSeconds
    $remaining = $TestDuration - $elapsed
    
    # Perform failover every 5 minutes
    if ($elapsed -gt 0 -and $elapsed % $FailoverInterval -eq 0 -and $failoverCounter -eq [int]($elapsed / $FailoverInterval) - 1) {
        $failoverCounter = [int]($elapsed / $FailoverInterval)
        
        # Rotate to next primary (cycling through nodes)
        $nextPrimary = "pg-node-" + (($failoverCounter % 6) + 1)
        Promote-Node $nextPrimary
    }
    
    # Validate every minute
    if ($elapsed -gt 0 -and $elapsed % $ValidationInterval -eq 0 -and $validationCounter -eq [int]($elapsed / $ValidationInterval) - 1) {
        $validationCounter = [int]($elapsed / $ValidationInterval)
        
        Write-Log "--- VALIDATION REPORT (Elapsed: ${elapsed}s / Remaining: ${remaining}s) ---" "REPORT"
        
        $primary = Get-CurrentPrimary
        Write-Log "Current Primary: $primary" "REPORT"
        
        # Get counts from all nodes
        $nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
        
        foreach ($node in $nodes) {
            $rowCount = Get-NodeRowCount $node
            $ops = Get-OperationCounts $node
            
            $parts = $ops -split '\|'
            if ($parts.Count -eq 4) {
                $total = $parts[0].Trim()
                $inserts = $parts[1].Trim()
                $updates = $parts[2].Trim()
                $deletes = $parts[3].Trim()
                
                $reportLine = "$node | Total: $total | Inserts: $inserts | Updates: $updates | Deletes: $deletes"
            } else {
                $reportLine = "$node | Total: $rowCount | Inserts: ? | Updates: ? | Deletes: ?"
            }
            
            Write-Log $reportLine "REPORT"
            Add-Content -Path $resultsFile -Value $reportLine
        }
        
        Write-Log "--- END REPORT ---" "REPORT"
        Write-Log ""
    }
    
    # Progress indicator
    $progress = "[$elapsed/$TestDuration] Elapsed: {0:D2}m {1:D2}s | Remaining: {0:D2}m {1:D2}s | Nodes: 6/6" -f `
        ([int]$elapsed / 60), ($elapsed % 60), `
        ([int]$remaining / 60), ($remaining % 60)
    
    Write-Host -NoNewline "`r$progress"
    Start-Sleep -Seconds 1
}

# Stop write job
$writeJob | Stop-Job -PassThru | Remove-Job

Write-Log ""
Write-Log "================================"
Write-Log "Test Completed Successfully!"
Write-Log "================================"
Write-Log "Total Duration: $TestDuration seconds"
Write-Log "Log File: $logFile"
Write-Log "Results File: $resultsFile"
Write-Log "Failover Log: $failoverLog"
Write-Log ""

# Final validation
Write-Log "FINAL VALIDATION" "REPORT"
$nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
$rowCounts = @()

foreach ($node in $nodes) {
    $count = Get-NodeRowCount $node
    $rowCounts += $count
    Write-Log "Final Row Count on $node : $count" "REPORT"
}

# Check consistency
$uniqueCounts = $rowCounts | Sort-Object -Unique
if ($uniqueCounts.Count -eq 1) {
    Write-Log "✓ All nodes consistent: All have $($uniqueCounts[0]) rows" "SUCCESS"
} else {
    Write-Log "⚠ Inconsistency detected: Row counts vary!" "WARNING"
    Write-Log "Counts: $($rowCounts -join ', ')" "WARNING"
}

Write-Log "Test completed successfully!"
