# 30-Minute PostgreSQL HA Cluster Test with Restart Option (PowerShell)
# Tests: continuous writes, reads from all nodes, data sync verification
# Usage: .\test-30min.ps1 -Duration 1800 -AutoRestart:$false -LogDir "test-logs"

param(
    [int]$Duration = 1800,           # 30 minutes in seconds
    [bool]$AutoRestart = $false,     # Enable auto-restart after test
    [string]$LogDir = "test-logs"
)

# Create log directory
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = "$LogDir/test-$timestamp.log"
$MetricsFile = "$LogDir/metrics-$timestamp.log"
$RestartLog = "$LogDir/restart.log"

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

function Get-NodeStatus {
    $nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
    $running = 0
    foreach ($node in $nodes) {
        $status = docker ps --filter "name=$node" --format "{{.State}}" 2>$null
        if ($status -eq "running") { $running++ }
    }
    return $running
}

function Get-RowCount {
    param([string]$Node)
    try {
        $count = docker exec $Node psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        return $count
    }
    catch {
        return "?"
    }
}

function Initialize-TestTable {
    Write-Info "Initializing test table..."
    docker exec pg-node-1 psql -U appuser -d appdb -c "
        CREATE TABLE IF NOT EXISTS test_data (
            id SERIAL PRIMARY KEY,
            test_value VARCHAR(255),
            created_at TIMESTAMP
        );" 2>$null
    Write-Success "Test table created"
}

function Write-TestData {
    param([int]$DurationSeconds)
    
    Write-Log "Starting write workload to pg-node-1:5432"
    
    $batchCount = 0
    $startTime = Get-Date
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -gt $DurationSeconds) { break }
        
        for ($i = 1; $i -le 10; $i++) {
            $value = "batch_$batchCount-row_$i"
            docker exec pg-node-1 psql -U appuser -d appdb -c `
                "INSERT INTO test_data (test_value, created_at) VALUES ('$value', NOW());" 2>$null
        }
        
        $batchCount++
        
        if ($batchCount % 10 -eq 0) {
            $totalRows = Get-RowCount "pg-node-1"
            $metric = "$(Get-Date -Format 'HH:mm:ss') - Write batches: $batchCount | Total rows: $totalRows"
            Add-Content -Path $MetricsFile -Value $metric
        }
        
        Start-Sleep -Milliseconds 500
    }
}

function Read-TestData {
    param([int]$DurationSeconds)
    
    Write-Log "Starting read workload from all nodes"
    
    $nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
    $startTime = Get-Date
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -gt $DurationSeconds) { break }
        
        foreach ($node in $nodes) {
            docker exec $node psql -U appuser -d appdb -c `
                "SELECT COUNT(*) FROM test_data LIMIT 1;" 2>$null | Out-Null
        }
        
        Start-Sleep -Seconds 2
    }
}

function Validate-Replication {
    param([int]$DurationSeconds)
    
    Write-Log "Starting replication validation"
    
    $nodes = @("pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
    $startTime = Get-Date
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -gt $DurationSeconds) { break }
        
        $primaryCount = Get-RowCount "pg-node-1"
        $allMatch = $true
        
        foreach ($node in $nodes) {
            $nodeCount = Get-RowCount $node
            
            if ($nodeCount -ne $primaryCount) {
                $allMatch = $false
                $metric = "$(Get-Date -Format 'HH:mm:ss') - ⚠ Sync lag on $node : primary=$primaryCount vs $node=$nodeCount"
                Add-Content -Path $MetricsFile -Value $metric
                break
            }
        }
        
        if ($allMatch -and $primaryCount -ne "?") {
            $metric = "$(Get-Date -Format 'HH:mm:ss') - ✓ All nodes synced: $primaryCount rows"
            Add-Content -Path $MetricsFile -Value $metric
        }
        
        Start-Sleep -Seconds 10
    }
}

function Cleanup-Test {
    Write-Log "Cleaning up test environment..."
    docker exec pg-node-1 psql -U appuser -d appdb -c "DROP TABLE IF EXISTS test_data;" 2>$null
}

function Handle-Restart {
    if (!$AutoRestart) { return }
    
    Write-Log "Auto-Restart enabled - restarting cluster"
    Add-Content -Path $RestartLog -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Restarting cluster"
    
    Write-Info "Stopping all containers..."
    docker compose -f docker-compose.yml stop 2>&1 | ForEach-Object { Write-Log $_ }
    
    Start-Sleep -Seconds 10
    
    Write-Info "Restarting containers..."
    docker compose -f docker-compose.yml start 2>&1 | ForEach-Object { Write-Log $_ }
    
    Start-Sleep -Seconds 20
    
    # Verify cluster health
    $healthCheck = 0
    $nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
    
    foreach ($node in $nodes) {
        $status = docker exec $node pg_isready -U appuser -d appdb 2>$null
        if ($status -like "*accepting*") { $healthCheck++ }
    }
    
    if ($healthCheck -eq 6) {
        Write-Success "Cluster restarted and healthy ($healthCheck/6 nodes)"
        Write-Log "Cluster restarted successfully - all 6 nodes healthy"
    } else {
        Write-Error-Custom "Cluster restart incomplete ($healthCheck/6 nodes healthy)"
        Write-Log "Cluster restart incomplete - only $healthCheck/6 nodes healthy" "ERROR"
    }
}

# Main execution
function Main {
    Write-Header "PostgreSQL HA Cluster - 30 Minute Test"
    
    Write-Log "Test Configuration:"
    Write-Log "  Duration: $Duration seconds ($(($Duration / 60)) minutes)"
    Write-Log "  Auto-Restart: $AutoRestart"
    Write-Log "  Log File: $LogFile"
    Write-Log "  Metrics File: $MetricsFile"
    
    # Initialize
    Initialize-TestTable
    
    # Start workloads in parallel
    Write-Info "Starting workloads..."
    
    $writeJob = Start-Job -ScriptBlock ${function:Write-TestData} -ArgumentList $Duration
    $readJob = Start-Job -ScriptBlock ${function:Read-TestData} -ArgumentList $Duration
    $validateJob = Start-Job -ScriptBlock ${function:Validate-Replication} -ArgumentList $Duration
    
    Write-Success "All workloads started"
    ""
    
    # Monitor test duration
    Write-Info "Test running for 30 minutes..."
    $startTime = Get-Date
    
    while ($true) {
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        $remaining = $Duration - $elapsed
        
        if ($remaining -le 0) {
            Write-Info "Test duration complete (30 minutes)"
            break
        }
        
        $minutes = [int]($remaining / 60)
        $seconds = [int]($remaining % 60)
        $podsRunning = Get-NodeStatus
        $status = "Elapsed: $(([int]$elapsed))s | Remaining: ${minutes}m ${seconds}s | Nodes: ${podsRunning}/6"
        
        Write-Host -NoNewline "`r$status"
        Start-Sleep -Seconds 5
    }
    
    ""
    
    # Stop jobs
    $writeJob, $readJob, $validateJob | Stop-Job -PassThru | Remove-Job
    
    # Handle restart
    Handle-Restart
    
    # Cleanup
    Cleanup-Test
    
    # Summary
    Write-Header "Test Summary"
    
    $finalRows = Get-RowCount "pg-node-1"
    
    Write-Success "Test completed successfully"
    Write-Info "Final row count: $finalRows"
    Write-Info "Log: $LogFile"
    Write-Info "Metrics: $MetricsFile"
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
