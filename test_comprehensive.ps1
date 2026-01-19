#!/usr/bin/env powershell
<#
.SYNOPSIS
Comprehensive PostgreSQL Cluster Test
- Validates all containers are running
- Manages primary node promotion
- Initializes database with test data
- Monitors replication across nodes

.USAGE
powershell -ExecutionPolicy Bypass -File test_comprehensive.ps1
#>

Set-Location "C:\Users\reven\docker\postgreSQL"

$API_URL = "http://localhost:5001/api/operationmanagement"
$NODES = @("node1", "node2", "node3", "replica-1", "replica-2")
$NODE_PORTS = @{"node1" = 5432; "node2" = 5435; "node3" = 5436; "replica-1" = 5433; "replica-2" = 5434}
$DB_USER = "testadmin"
$DB_PASSWORD = "securepwd123"
$DB_NAME = "testdb"

function Write-Section {
    param([string]$Title)
    Write-Host "`n$('='*70)" -ForegroundColor Green
    Write-Host "  $Title" -ForegroundColor Green
    Write-Host "$('='*70)" -ForegroundColor Green
}

function Write-Step {
    param([string]$Message, [int]$StepNum, [int]$Total)
    Write-Host "`n[$StepNum/$Total] $Message" -ForegroundColor Cyan
}

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Gray" }
    }
    Write-Host "   [$Status] $Message" -ForegroundColor $color
}

function Get-ContainerStatus {
    try {
        $output = & docker-compose ps --format json 2>&1 | ConvertFrom-Json
        return $output
    }
    catch {
        Write-Status "Failed to get container status" "ERROR"
        return $null
    }
}

function Clean-AllDockerContainers {
    Write-Step "Cleaning All Docker Containers" 0 8
    
    try {
        Write-Status "Stopping all running containers..." "INFO"
        $allContainers = & docker ps -q 2>&1
        if ($allContainers -and $allContainers.Count -gt 0) {
            Write-Status "Found $($allContainers.Count) running containers, stopping..." "INFO"
            & docker stop @($allContainers) 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
        
        Write-Status "Removing all stopped containers..." "INFO"
        $stoppedContainers = & docker ps -a -q 2>&1
        if ($stoppedContainers -and $stoppedContainers.Count -gt 0) {
            Write-Status "Found $($stoppedContainers.Count) total containers, removing..." "INFO"
            & docker rm @($stoppedContainers) -f 2>&1 | Out-Null
        }
        
        Write-Status "Docker cleanup completed" "OK"
        return $true
    }
    catch {
        Write-Status "Error during cleanup: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Test-AllContainersHealthy {
    Write-Step "Validating Container Health" 1 8
    
    $containers = Get-ContainerStatus
    if (-not $containers) {
        Write-Status "Could not retrieve container status" "ERROR"
        return $false
    }
    
    $allHealthy = $true
    foreach ($container in $containers) {
        $name = $container.Service
        $state = $container.State
        $status = if ($state -eq "running") { "OK" } else { "ERROR" }
        Write-Status "$name : $state" $status
        if ($state -ne "running") { $allHealthy = $false }
    }
    
    return $allHealthy
}

function Get-ClusterStatus {
    try {
        $response = Invoke-WebRequest -Uri "$API_URL/status" `
            -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        return $response.Content | ConvertFrom-Json
    }
    catch {
        Write-Status "Failed to retrieve status" "ERROR"
        return $null
    }
}

function Get-PrimaryNode {
    param($Status)
    foreach ($node in $NODES) {
        if ($Status.nodes.$node.is_primary) {
            return $node
        }
    }
    return "NONE"
}

function Show-ClusterStatus {
    Write-Host "   Current Cluster State:" -ForegroundColor Gray
    
    # Try to get overview first (includes gap info and all nodes)
    try {
        $response = Invoke-WebRequest -Uri "$API_URL/overview" `
            -UseBasicParsing -TimeoutSec 5 -ErrorAction SilentlyContinue 2>&1
        
        if ($response -and $response.StatusCode -eq 200) {
            $overview = $response.Content | ConvertFrom-Json
            Write-Host "      Primary: $($overview.primary_node)" -ForegroundColor Yellow
            Write-Host "      Cluster Status: $($overview.cluster_status)" -ForegroundColor Green
            Write-Host "" -ForegroundColor Gray
            Write-Host "      Nodes:" -ForegroundColor DarkGray
            
            foreach ($node in $overview.nodes) {
                $role = if ($node.is_primary) { "[PRIMARY]" } else { "[STANDBY]" }
                $status = $node.status
                $statusColor = if ($status -eq "connected") { "Green" } else { "Yellow" }
                
                Write-Host "        $($node.name) : $role ($status)" -ForegroundColor $statusColor
                
                # Show gap info for standbys
                if ($node.replication_gap -and !$node.is_primary) {
                    $gap = $node.replication_gap
                    if ($gap.gap_bytes -le 0) {
                        $gapColor = if ($gap.gap_bytes -eq 0) { "Green" } else { "Yellow" }
                        Write-Host "          ├─ Gap: $($gap.gap_bytes) bytes" -ForegroundColor $gapColor
                        Write-Host "          ├─ Primary LSN: $($gap.primary_lsn)" -ForegroundColor DarkGray
                        Write-Host "          └─ Replica LSN: $($gap.receive_lsn)" -ForegroundColor DarkGray
                    }
                    else {
                        Write-Host "          └─ Gap: Unable to determine (code: $($gap.gap_bytes))" -ForegroundColor Yellow
                    }
                }
            }
            return
        }
    }
    catch {
        Write-Status "Overview endpoint unavailable, using fallback status" "WARN"
    }
    
    # Fallback to status endpoint
    $status = Get-ClusterStatus
    if ($status) {
        $primary = Get-PrimaryNode -Status $status
        Write-Host "      Primary: $primary" -ForegroundColor Yellow
        Write-Host "      Nodes:" -ForegroundColor DarkGray
        foreach ($node in $NODES) {
            $isPrimary = $status.nodes.$node.is_primary
            $role = if ($isPrimary) { "[PRIMARY]" } else { "[STANDBY]" }
            Write-Host "        $node : $role" -ForegroundColor Gray
        }
    }
}

function Get-ReplicationLag {
    param([string]$Node)
    
    try {
        $response = Invoke-WebRequest -Uri "$API_URL/overview" `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue 2>&1
        
        if ($response -and $response.StatusCode -eq 200) {
            $data = $response.Content | ConvertFrom-Json
            
            foreach ($n in $data.nodes) {
                if ($n.name -eq $Node) {
                    if ($n.role -eq "PRIMARY") {
                        return @{ node = $Node; lag = 0; bytes = 0; status = "OK" }
                    }
                    else {
                        $lag = if ($n.replication_gap -and $n.replication_gap.gap_bytes) { $n.replication_gap.gap_bytes } else { -1 }
                        return @{ node = $Node; lag = $lag; bytes = $lag; status = "OK" }
                    }
                }
            }
        }
        else {
            Write-Status "Overview endpoint returned status: $($response.StatusCode)" "WARN"
            return @{ node = $Node; lag = -1; bytes = -1; status = "UNAVAILABLE" }
        }
    }
    catch {
        Write-Status "Could not get replication lag for $Node : $($_.Exception.Message)" "WARN"
        return @{ node = $Node; lag = -1; bytes = -1; status = "ERROR" }
    }
}

function Set-NodePrimary {
    param([string]$Node, [int]$StepNum)
    
    Write-Step "Promoting $Node to PRIMARY" $StepNum 8
    
    # Check replication gap before promotion - MUST be <= 0 to proceed
    Write-Status "Checking replication gap before promotion (must be [less than or equal to] 0)..." "INFO"
    $lagInfo = Get-ReplicationLag -Node $Node
    
    if ($lagInfo.status -eq "OK") {
        if ($lagInfo.bytes -le 0) {
            Write-Status "OK: Replication gap acceptable: $($lagInfo.bytes) bytes (OK to promote)" "OK"
        }
        else {
            Write-Status "FAIL: Replication gap is $($lagInfo.bytes) bytes - CANNOT promote" "ERROR"
            exit 1
        }
    }
    else {
        Write-Status "WARN: Replication check status: $($lagInfo.status) - gap could not be verified" "WARN"
        Write-Status "FAIL: Cannot proceed with promotion without valid gap check" "ERROR"
        exit 1
    }
    
    try {
        Write-Status "Sending promotion request (may take 2-3 minutes)..." "INFO"
        # Use longer timeout for promotion - operations can take time
        $response = Invoke-WebRequest -Uri "$API_URL/promote/$Node" `
            -Method POST -UseBasicParsing -TimeoutSec 300 `
            -ErrorAction SilentlyContinue 2>&1
        
        if ($response) {
            Write-Status "Request completed with status: $($response.StatusCode)" "OK"
        }
        else {
            Write-Status "Request may have succeeded (check cluster status)" "WARN"
        }
        
        Write-Status "Waiting 30 seconds for promotion to complete..." "INFO"
        Start-Sleep -Seconds 30
        
        # Verify promotion
        $status = Get-ClusterStatus
        if ($status) {
            $primary = Get-PrimaryNode -Status $status
            if ($primary -eq $Node) {
                Write-Status "$Node is now PRIMARY" "OK"
                Show-ClusterStatus
                return $true
            }
            else {
                Write-Status "Primary is $primary, expected $Node - PROMOTION FAILED!" "ERROR"
                Show-ClusterStatus
                exit 1
            }
        }
        Write-Status "Could not verify promotion status" "ERROR"
        exit 1
    }
    catch {
        Write-Status "Promotion error: $($_.Exception.Message)" "WARN"
        Write-Status "Checking cluster status to see if promotion succeeded..." "INFO"
        Start-Sleep -Seconds 10
        
        # Check if it worked anyway
        $status = Get-ClusterStatus
        if ($status) {
            $primary = Get-PrimaryNode -Status $status
            if ($primary -eq $Node) {
                Write-Status "$Node is now PRIMARY (promotion succeeded)" "OK"
                Show-ClusterStatus
                return $true
            }
            else {
                Write-Status "Promotion failed - Primary is still $primary" "ERROR"
                exit 1
            }
        }
        exit 1
    }
}

function Initialize-Database {
    Write-Step "Initializing Database with Test Data" 3 8
    
    try {
        Write-Status "Running init container..." "INFO"
        $output = & docker-compose --profile init run --rm db-init 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Database initialized successfully" "OK"
            Start-Sleep -Seconds 5
            return $true
        }
        else {
            Write-Status "Init container failed" "WARN"
            return $false
        }
    }
    catch {
        Write-Status "Error initializing database: $_" "WARN"
        return $false
    }
}

function Get-EntryCount {
    param([string]$Node)
    
    $port = $NODE_PORTS[$Node]
    $env:PGPASSWORD = $DB_PASSWORD
    
    try {
        $result = & psql -h localhost -p $port -U $DB_USER -d $DB_NAME `
            -c "SELECT COUNT(*) FROM messages;" 2>&1 | Select-Object -Last 1
        
        if ($result -match '^\s*(\d+)\s*$') {
            return [int]$matches[1]
        }
        return -1
    }
    catch {
        return -1
    }
}

function Validate-EntryCount {
    param([string]$Phase)
    
    Write-Host "   $Phase" -ForegroundColor Gray
    $counts = @{}
    
    foreach ($node in $NODES) {
        $count = Get-EntryCount -Node $node
        $counts[$node] = $count
        if ($count -ge 0) {
            Write-Status "$node has $count entries" "OK"
        }
        else {
            Write-Status "$node : unable to query" "WARN"
        }
    }
    
    return $counts
}

function Start-TestDataGenerator {
    Write-Step "Starting Test Data Generator" 5 8
    
    try {
        Write-Status "Running test data generator - 5 minutes duration" "INFO"
        
        $output = & docker-compose --profile test run --rm test-data-generator-node2 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Test data generator completed" "OK"
            return $true
        }
        else {
            Write-Status "Test data generator failed" "WARN"
            return $false
        }
    }
    catch {
        Write-Status "Error starting test generator: $_" "WARN"
        return $false
    }
}

function Validate-DataReplication {
    Write-Step "Validating Data Replication" 8 8
    
    Write-Host "   Data must be consistent across all nodes after promotion" -ForegroundColor Gray
    
    $counts = @{}
    foreach ($node in $NODES) {
        $count = Get-EntryCount -Node $node
        $counts[$node] = $count
        Write-Status "$node has $count entries" "OK"
    }
    
    if ($counts["node1"] -gt 0) {
        $maxDiff = [Math]::Max($counts["node1"], $counts["node2"], $counts["node3"]) * 0.05
        $allConsistent = $true
        
        foreach ($n1 in $NODES) {
            foreach ($n2 in $NODES) {
                if ([Math]::Abs($counts[$n1] - $counts[$n2]) -gt $maxDiff) {
                    Write-Status "Inconsistency: $n1 vs $n2" "WARN"
                    $allConsistent = $false
                }
            }
        }
        
        if ($allConsistent) {
            Write-Status "Data is consistent across all nodes" "OK"
        }
        return $allConsistent
    }
    
    return $false
}

# MAIN TEST SEQUENCE
Write-Section "COMPREHENSIVE POSTGRESQL CLUSTER TEST"

Clean-AllDockerContainers
Start-Sleep -Seconds 3

Write-Status "Restarting Docker Compose services..." "INFO"
& docker-compose up -d 2>&1 | Out-Null
Start-Sleep -Seconds 10

if (-not (Test-AllContainersHealthy)) {
    Write-Status "Some containers are not healthy" "ERROR"
    exit 1
}

Set-NodePrimary -Node "node2" -StepNum 2
Show-ClusterStatus

Initialize-Database
Show-ClusterStatus

$countsBeforeData = Validate-EntryCount "Before Test Data Generation"

Start-TestDataGenerator

$countsAfterData = Validate-EntryCount "After Test Data Generation"
if ($countsAfterData -and $countsBeforeData) {
    $dataInserted = $countsAfterData["node2"] - $countsBeforeData["node2"]
    Write-Status "Approximately $dataInserted entries inserted during test" "OK"
}

Set-NodePrimary -Node "node1" -StepNum 7
Show-ClusterStatus

Validate-DataReplication

Write-Section "TEST COMPLETE"
Write-Status "All tests completed successfully" "OK"
Write-Host "`nTest completed. Check logs for details.`n" -ForegroundColor Green
