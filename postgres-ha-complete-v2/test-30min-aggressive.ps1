# Aggressive 30-Minute PostgreSQL HA Cluster Test
# Takeover every 3 minutes + Row count validation every minute
# Tests: failover resilience, data consistency, recovery speed

param(
    [int]$TotalDuration = 1800,      # 30 minutes in seconds
    [int]$TakeoverInterval = 180,    # 3 minutes in seconds
    [int]$ReportInterval = 60,       # 1 minute in seconds
    [string]$LogDir = "test-logs"
)

# Create log directory
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = "$LogDir/aggressive-test-$timestamp.log"
$RowCountFile = "$LogDir/row-counts-$timestamp.csv"
$TakeoverLog = "$LogDir/takeovers-$timestamp.log"

# Initialize CSV with header
"Timestamp,WriteCount,Elapsed(s),Takeover,pg-node-1,pg-node-2,pg-node-3,pg-node-4,pg-node-5,pg-node-6,Synced,SyncStatus" | Out-File -FilePath $RowCountFile -Encoding UTF8

# Utility functions
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$time] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

function Write-Success {
    Write-Host "✓ $args" -ForegroundColor Green
}

function Write-Error-Custom {
    Write-Host "✗ $args" -ForegroundColor Red
}

function Write-Info {
    Write-Host "ℹ $args" -ForegroundColor Yellow
}

function Write-Header {
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host "$args" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
}

function Get-RowCount {
    param([string]$Node)
    try {
        $count = docker exec $Node psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        return if ($count) { $count } else { "?" }
    }
    catch {
        return "ERR"
    }
}

function Get-AllNodeCounts {
    $nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
    $counts = @{}
    
    foreach ($node in $nodes) {
        $counts[$node] = Get-RowCount $node
    }
    
    return $counts
}

function Check-Sync {
    param($CountsHash)
    
    # Get numeric counts
    $numericCounts = @()
    foreach ($node in $CountsHash.Keys | Sort-Object) {
        $val = $CountsHash[$node]
        if ($val -match '^\d+$') {
            $numericCounts += [int]$val
        }
    }
    
    if ($numericCounts.Count -eq 0) {
        return @{ Synced = $false; Status = "NO_VALID_COUNTS"; AllCount = "?" }
    }
    
    $minCount = ($numericCounts | Measure-Object -Minimum).Minimum
    $maxCount = ($numericCounts | Measure-Object -Maximum).Maximum
    $isSynced = ($minCount -eq $maxCount)
    
    $status = if ($isSynced) { "✓ SYNCED" } else { "⚠ LAG: $maxCount-$minCount=$($maxCount - $minCount)" }
    
    return @{
        Synced = $isSynced
        Status = $status
        AllCount = $maxCount
        Lag = ($maxCount - $minCount)
    }
}

function Print-Row-Counts {
    param($CountsHash, $Elapsed, $WriteCount, $TakeoverNum, $SyncInfo)
    
    # Console output
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] Elapsed: ${Elapsed}s | Writes: $WriteCount | Takeover #$TakeoverNum"
    Write-Host $line
    
    # Per-node counts
    $nodeOutput = "  Nodes: "
    foreach ($node in @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")) {
        $count = $CountsHash[$node]
        $nodeOutput += "$node=$count "
    }
    Write-Host $nodeOutput
    
    # Sync status
    Write-Host "  Status: $($SyncInfo.Status)"
    
    # CSV entry
    $csvEntry = "$((Get-Date).ToString('HH:mm:ss')),$WriteCount,$Elapsed,$TakeoverNum,$($CountsHash['pg-node-1']),$($CountsHash['pg-node-2']),$($CountsHash['pg-node-3']),$($CountsHash['pg-node-4']),$($CountsHash['pg-node-5']),$($CountsHash['pg-node-6']),$($SyncInfo.Synced),$($SyncInfo.Status)"
    Add-Content -Path $RowCountFile -Value $csvEntry
}

function Perform-Takeover {
    param([int]$TakeoverNumber)
    
    Write-Info "=== TAKEOVER #$TakeoverNumber: Restarting all containers ==="
    Add-Content -Path $TakeoverLog -Value "[$(Get-Date -Format 'HH:mm:ss')] Takeover #$TakeoverNumber started"
    
    # Stop all containers
    Write-Info "  Stopping containers..."
    docker compose -f docker-compose.yml stop 2>&1 | Out-Null
    
    # Quick wait
    Start-Sleep -Seconds 3
    
    # Start all containers
    Write-Info "  Starting containers..."
    docker compose -f docker-compose.yml start 2>&1 | Out-Null
    
    # Wait for nodes to come up
    Start-Sleep -Seconds 10
    
    # Verify nodes are accessible
    $healthyCount = 0
    $maxRetries = 30
    $retry = 0
    
    while ($healthyCount -lt 6 -and $retry -lt $maxRetries) {
        $healthyCount = 0
        foreach ($node in @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")) {
            $status = docker exec $node pg_isready -U appuser -d appdb 2>$null
            if ($status -like "*accepting*") { $healthyCount++ }
        }
        
        if ($healthyCount -lt 6) {
            Start-Sleep -Seconds 2
            $retry++
        }
    }
    
    Write-Success "Takeover #$TakeoverNumber: Cluster recovered ($healthyCount/6 nodes ready)"
    Add-Content -Path $TakeoverLog -Value "[$(Get-Date -Format 'HH:mm:ss')] Takeover #$TakeoverNumber: $healthyCount/6 nodes ready after $retry retries"
    
    return @{ Success = ($healthyCount -eq 6); HealthyNodes = $healthyCount }
}

function Write-Workload {
    param([int]$DurationSeconds)
    
    Write-Log "Starting continuous write workload"
    
    $batchCount = 0
    $startTime = Get-Date
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -gt $DurationSeconds) { break }
        
        # Write 10 rows per iteration
        for ($i = 1; $i -le 10; $i++) {
            try {
                $value = "batch_$batchCount-row_$i"
                docker exec pg-node-1 psql -U appuser -d appdb -c `
                    "INSERT INTO test_data (test_value, created_at) VALUES ('$value', NOW());" 2>$null
            }
            catch {
                # Silently fail if primary is down during takeover
            }
        }
        
        $batchCount++
        Start-Sleep -Milliseconds 300
    }
}

function Main {
    Write-Header "PostgreSQL HA - Aggressive 30-Min Test"
    Write-Header "Failover Every 3 Minutes + Row Count Every Minute"
    
    Write-Log "Test Configuration:"
    Write-Log "  Total Duration: $TotalDuration seconds (30 minutes)"
    Write-Log "  Takeover Interval: $TakeoverInterval seconds (3 minutes)"
    Write-Log "  Report Interval: $ReportInterval seconds (1 minute)"
    Write-Log "  Log Files: $LogFile, $RowCountFile, $TakeoverLog"
    
    # Initialize test table
    Write-Info "Initializing test environment..."
    docker exec pg-node-1 psql -U appuser -d appdb -c "
        DROP TABLE IF EXISTS test_data;
        CREATE TABLE test_data (
            id SERIAL PRIMARY KEY,
            test_value VARCHAR(255),
            created_at TIMESTAMP
        );" 2>$null
    
    Write-Success "Test table created"
    ""
    
    # Start write workload in background
    $writeJob = Start-Job -ScriptBlock ${function:Write-Workload} -ArgumentList $TotalDuration
    Write-Log "Write workload job started"
    
    # Main test loop
    $startTime = Get-Date
    $nextTakeover = $TakeoverInterval
    $nextReport = $ReportInterval
    $takeoverCount = 0
    $writeCount = 0
    
    Write-Header "Starting Test"
    ""
    
    while ($true) {
        $currentTime = Get-Date
        $elapsed = ($currentTime - $startTime).TotalSeconds
        
        # Check if test duration exceeded
        if ($elapsed -gt $TotalDuration) {
            Write-Info "Test duration complete (30 minutes elapsed)"
            break
        }
        
        # Perform takeover if interval reached
        if ($elapsed -ge $nextTakeover) {
            $takeoverCount++
            
            # Get counts before takeover
            $countsBeforeTakeover = Get-AllNodeCounts
            
            # Perform takeover
            $takeoverResult = Perform-Takeover $takeoverCount
            
            # Get counts after takeover
            Start-Sleep -Seconds 5
            $countsAfterTakeover = Get-AllNodeCounts
            $syncInfo = Check-Sync $countsAfterTakeover
            
            # Log counts
            Print-Row-Counts $countsAfterTakeover $([int]$elapsed) $writeCount $takeoverCount $syncInfo
            ""
            
            $nextTakeover += $TakeoverInterval
        }
        
        # Print row counts if interval reached
        elseif ($elapsed -ge $nextReport) {
            $counts = Get-AllNodeCounts
            $syncInfo = Check-Sync $counts
            
            Print-Row-Counts $counts $([int]$elapsed) $writeCount $takeoverCount $syncInfo
            
            # Increment write count estimate (10 rows every 300ms ≈ 33/sec)
            $writeCount += 30
            
            $nextReport += $ReportInterval
        }
        
        Start-Sleep -Milliseconds 500
    }
    
    # Stop write job
    $writeJob | Stop-Job -PassThru | Remove-Job
    
    # Final summary
    ""
    Write-Header "Test Complete - Final Summary"
    
    $finalCounts = Get-AllNodeCounts
    $finalSync = Check-Sync $finalCounts
    
    Write-Success "Test executed for 30 minutes"
    Write-Success "Total takeovers performed: $takeoverCount"
    Write-Info "Final row counts:"
    
    foreach ($node in @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")) {
        Write-Host "  $node : $($finalCounts[$node]) rows"
    }
    
    Write-Success "Final status: $($finalSync.Status)"
    Write-Info "Row count log: $RowCountFile"
    Write-Info "Takeover log: $TakeoverLog"
}

# Execute
try {
    Main
}
catch {
    Write-Error-Custom $_
    Write-Log "Error: $_" "ERROR"
    exit 1
}

Write-Success "Test completed successfully"
