param(
    [int]$Duration = 1800,
    [string]$LogDir = "test-logs"
)

if (!(Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = "$LogDir/read-load-$timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $time = Get-Date -Format "HH:mm:ss"
    $entry = "[$time] [$Level] $Message"
    Write-Host $entry
    Add-Content -Path $logFile -Value $entry
}

Write-Log "Read Load Generator Started"
Write-Log "Target: pg-node-4, pg-node-5, pg-node-6"
Write-Log ""

$readOnlyNodes = @("pg-node-4", "pg-node-5", "pg-node-6")
$readJobs = @()

foreach ($node in $readOnlyNodes) {
    Write-Log "Starting read workload on $node"
    
    $job = Start-Job -ScriptBlock {
        param($nodeName, $duration)
        $startTime = Get-Date
        $queryCount = 0
        
        while ((Get-Date) - $startTime -lt [timespan]::FromSeconds($duration)) {
            try {
                docker exec $nodeName psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;" > $null 2>&1
                docker exec $nodeName psql -U appuser -d appdb -t -c "SELECT MAX(id), MIN(id) FROM test_data;" > $null 2>&1
                docker exec $nodeName psql -U appuser -d appdb -t -c "SELECT operation_type, COUNT(*) FROM test_data GROUP BY operation_type;" > $null 2>&1
                docker exec $nodeName psql -U appuser -d appdb -t -c "SELECT * FROM test_data ORDER BY id DESC LIMIT 100;" > $null 2>&1
                docker exec $nodeName psql -U appuser -d appdb -t -c "SELECT * FROM test_data LIMIT 50;" > $null 2>&1
                $queryCount += 5
            }
            catch { }
            Start-Sleep -Milliseconds 50
        }
        return $queryCount
    } -ArgumentList $node, $Duration
    
    $readJobs += @{ Node = $node; Job = $job }
    Start-Sleep -Milliseconds 300
}


Write-Log "Read workload started on all 3 read-only nodes"
Write-Log ""

$elapsed = 0
$startTime = Get-Date

while ($elapsed -lt $Duration) {
    $elapsed = [int]((Get-Date) - $startTime).TotalSeconds
    $remaining = $Duration - $elapsed
    
    $progress = "[$elapsed/$Duration] {0:D2}m {1:D2}s | Remaining: {2:D2}m {3:D2}s" -f `
        ([int]$elapsed / 60), ($elapsed % 60), `
        ([int]$remaining / 60), ($remaining % 60)
    
    Write-Host -NoNewline "`r$progress"
    Start-Sleep -Seconds 2
}

Write-Log ""
Write-Log "Read load generation complete"

$readJobs | ForEach-Object {
    $result = Receive-Job -Job $_.Job -Wait
    Write-Log "Final: $($_.Node) = $result queries"
}
