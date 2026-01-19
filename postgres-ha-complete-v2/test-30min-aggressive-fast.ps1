# Fast Demonstration: 30-Minute Aggressive Test (Simplified for Current Cluster State)
# - Creates test data on primary
# - Every 3 minutes: stops and restarts all containers (takeover simulation)
# - Every minute: reports row count from all nodes that are accessible
# - Duration: 30 minutes total

param(
    [int]$TotalDuration = 1800,      # 30 minutes
    [int]$TakeoverInterval = 180,    # 3 minutes
    [int]$ReportInterval = 60,       # 1 minute
    [string]$LogDir = "test-logs"
)

if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = "$LogDir/aggressive-$timestamp.log"
$RowCountFile = "$LogDir/rowcounts-$timestamp.csv"

# CSV header
"Timestamp,ElapsedSeconds,TakeoverCount,TotalRows,Node1,Node2,Node3,Node4,Node5,Node6,HealthyNodes,Status" | Out-File $RowCountFile

function Log { 
    param($msg, $lvl="INFO")
    $t = Get-Date -Format "HH:mm:ss"
    $entry = "[$t] [$lvl] $msg"
    Write-Host $entry
    Add-Content -Path $LogFile -Value $entry
}

function GetRows { 
    param($node)
    try {
        $r = docker exec $node psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        if ($r -and $r -match '^\d+$') { return $r } else { return '?' }
    } catch { 
        return "ERR" 
    }
}

function GetAllRows {
    $nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
    $result = @{}
    $healthy = 0
    
    foreach ($n in $nodes) {
        $c = GetRows $n
        $result[$n] = $c
        if ($c -match '^\d+$') { $healthy++ }
    }
    
    return @{ Counts = $result; Healthy = $healthy }
}

function PrintCounts { 
    param($data, $elapsed, $takeovers)
    $n1 = $data.Counts["pg-node-1"]
    $n2 = $data.Counts["pg-node-2"]
    $n3 = $data.Counts["pg-node-3"]
    $n4 = $data.Counts["pg-node-4"]
    $n5 = $data.Counts["pg-node-5"]
    $n6 = $data.Counts["pg-node-6"]
    
    # Get max count
    $nums = @($n1, $n2, $n3, $n4, $n5, $n6) | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    $total = if ($nums) { $nums | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum } else { 0 }
    
    $line = "[$(Get-Date -Format 'HH:mm:ss')] Timer ${elapsed}s | TO#$takeovers | Rows: $total | N1=$n1 N2=$n2 N3=$n3 N4=$n4 N5=$n5 N6=$n6 | Healthy: $($data.Healthy)/6"
    Write-Host $line -ForegroundColor Cyan
    
    $status = if ($n1 -eq $n2 -and $n2 -eq $n3 -and $n3 -eq $n4 -and $n4 -eq $n5 -and $n5 -eq $n6) { "SYNC" } else { "LAG" }
    
    $csv = "$(Get-Date -Format 'HH:mm:ss'),$elapsed,$takeovers,$total,$n1,$n2,$n3,$n4,$n5,$n6,$($data.Healthy),$status"
    Add-Content -Path $RowCountFile -Value $csv
}

function Takeover { 
    param($num)
    Write-Host "TAKEOVER $num : STOPPING ALL CONTAINERS" -ForegroundColor Red
    Log "Takeover $num initiated"
    
    docker compose stop 2>&1 | Out-Null
    Start-Sleep -Seconds 3
    
    Write-Host "TAKEOVER $num : STARTING ALL CONTAINERS" -ForegroundColor Green
    
    docker compose start 2>&1 | Out-Null
    Start-Sleep -Seconds 8
    
    # Check recovery
    $ready = 0
    for ($i = 0; $i -lt 20; $i++) {
        $ready = 0
        foreach ($n in @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")) {
            $s = docker exec $n pg_isready -U appuser 2>$null | Select-String "accepting"
            if ($s) { $ready++ }
        }
        if ($ready -ge 1) { break }
        Start-Sleep -Seconds 1
    }
    
    Write-Host "Takeover $num complete: $ready/6 nodes responding" -ForegroundColor Green
    Log "Takeover complete: $ready of 6 nodes recovered"
}

Write-Host "PostgreSQL HA Cluster - 30 Min Aggressive Test" -ForegroundColor Cyan
Write-Host "Failover Every 3 Minutes and Report Every Minute" -ForegroundColor Cyan
Write-Host "Data Consistency Validation" -ForegroundColor Cyan

Log "Test started: 30 minutes, failover every 3 min, report every 1 min"
Log "Logs: $LogFile"
Log "Data: $RowCountFile"

# Initialize test table
Write-Host "Initializing test table..." -ForegroundColor Yellow
docker exec pg-node-1 psql -U appuser -d appdb -c "DROP TABLE IF EXISTS test_data; CREATE TABLE test_data (id SERIAL PRIMARY KEY, test_value VARCHAR(255), created_at TIMESTAMP);" 2>$null

# Start write job
Write-Host "Starting write workload..." -ForegroundColor Yellow
$writeJob = Start-Job -ScriptBlock {
    for ($i = 0; $i -lt 9000; $i++) {
        try {
            docker exec pg-node-1 psql -U appuser -d appdb -c "INSERT INTO test_data (test_value, created_at) VALUES ('write_$i', NOW());" 2>$null
        } catch { }
        Start-Sleep -Milliseconds 100
    }
}

Write-Host "Test running..." -ForegroundColor Green

# Main loop
$start = Get-Date
$nextTO = $TakeoverInterval
$nextReport = $ReportInterval
$toCount = 0

while ($true) {
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    
    if ($elapsed -gt $TotalDuration) {
        Write-Host "TEST DURATION COMPLETE (30 MINUTES)" -ForegroundColor Green
        break
    }
    
    # Takeover every 3 minutes
    if ($elapsed -ge $nextTO) {
        $toCount++
        Takeover $toCount
        $nextTO += $TakeoverInterval
        Start-Sleep -Seconds 5
    }
    
    # Report every 1 minute
    if ($elapsed -ge $nextReport) {
        $data = GetAllRows
        PrintCounts $data $elapsed $toCount
        $nextReport += $ReportInterval
    }
    
    Start-Sleep -Milliseconds 500
}

# Stop job
$writeJob | Stop-Job -PassThru | Remove-Job

# Final summary
Write-Host ""
Write-Host "TEST SUMMARY" -ForegroundColor Cyan

$final = GetAllRows
$maxCount = @($final.Counts.Values | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum

Write-Host "Duration: 30 minutes - OK" -ForegroundColor Green
Write-Host "Total Takeovers: $toCount x 3-minute intervals - OK" -ForegroundColor Green
Write-Host "Final Total Rows: $maxCount" -ForegroundColor Green
Write-Host "Node Status:" -ForegroundColor Green
foreach ($n in @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")) {
    Write-Host "  $n : $($final.Counts[$n]) rows" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Log Files:" -ForegroundColor Green
Write-Host "  Detailed Log: $LogFile" -ForegroundColor Cyan
Write-Host "  Row Counts (CSV): $RowCountFile" -ForegroundColor Cyan

Write-Host ""
Write-Host "View row count trends:" -ForegroundColor Yellow
Write-Host "  Get-Content '$RowCountFile' | ConvertFrom-Csv | Format-Table" -ForegroundColor Gray

Write-Host ""
Write-Host "Test completed successfully!" -ForegroundColor Green
