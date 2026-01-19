#!/usr/bin/env powershell
<#
.SYNOPSIS
Comprehensive PostgreSQL Cluster Test
- Validates all containers are running
- Manages primary node promotion
- Initializes database with test data
- Monitors replication across nodes
- Performs failover scenarios

.USAGE
powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
#>

Set-Location "C:\Users\reven\docker\postgreSQL"

# Global error flag
$script:TestFailed = $false

# Configuration
$API_URL = "http://localhost:5001/api/operationmanagement"
$NODES = @("node1", "node2", "node3")
$NODE_PORTS = @{
    "node1" = 5432
    "node2" = 5435
    "node3" = 5436
}
$DB_USER = "testadmin"
$DB_PASSWORD = "securepwd123"
$DB_NAME = "testdb"

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

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
    
    # Stop on error
    if ($Status -eq "ERROR") {
        $script:TestFailed = $true
        Write-Host "`n[CRITICAL] Test aborted due to error!" -ForegroundColor Red
        exit 1
    }
}

function Clean-AllDockerContainers {
    Write-Host "`n[CLEANUP] Removing ALL Docker containers (aggressive cleanup)..." -ForegroundColor Yellow
    try {
        # Stop all running containers
        Write-Host "   Stopping all running containers..." -ForegroundColor Gray
        $running = & docker ps -q 2>/dev/null
        if ($running) {
            & docker stop $running 2>&1 | Out-Null
        }
        
        # Remove all containers
        Write-Host "   Removing all containers..." -ForegroundColor Gray
        $all = & docker ps -a -q 2>/dev/null
        if ($all) {
            & docker rm -f $all 2>&1 | Out-Null
        }
        
        Write-Host "   All containers cleaned" -ForegroundColor Green
        Start-Sleep -Seconds 2
    }
    catch {
        Write-Status "Warning during container cleanup: $_" "WARN"
    }
}

function Get-ContainerStatus {
    Write-Host "   Checking containers..." -ForegroundColor Gray
    try {
        $output = & docker-compose ps --format json 2>&1 | ConvertFrom-Json
        return $output
    }
    catch {
        Write-Status "Failed to get container status" "ERROR"
        return $null
    }
}

function Test-AllContainersHealthy {
    Write-Step "Validating Container Health" 1 7
    
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

function Get-ReplicationLag {
    param([string]$CurrentPrimary, [string]$NewPrimary)
    
    Write-Status "Checking replication gap between $CurrentPrimary and $NewPrimary..." "INFO"
    
    try {
        $response = Invoke-WebRequest -Uri "$API_URL/overview" `
            -UseBasicParsing -TimeoutSec 30
        $overview = $response.Content | ConvertFrom-Json
        
        if (-not $overview -or -not $overview.nodes) {
            Write-Status "Could not retrieve replication overview" "WARN"
            return $false
        }
        
        # Find current primary's write_lag and new primary's replay_lag
        $primaryNode = $overview.nodes | Where-Object { $_.name -eq $CurrentPrimary }
        $candidateNode = $overview.nodes | Where-Object { $_.name -eq $NewPrimary }
        
        if (-not $primaryNode) {
            Write-Status "Current primary node $CurrentPrimary not found in cluster" "WARN"
            return $false
        }
        
        if (-not $candidateNode) {
            Write-Status "Candidate node $NewPrimary not found in cluster" "WARN"
            return $false
        }
        
        # Check if candidate is connected and replicating
        if ($candidateNode.role -ne "STANDBY") {
            Write-Status "Candidate $NewPrimary is not in STANDBY role (role: $($candidateNode.role))" "WARN"
            return $false
        }
        
        if (-not $candidateNode.connected) {
            Write-Status "Candidate $NewPrimary is not connected to primary" "ERROR"
            return $false
        }
        
        # Get replication lag info
        $replicaLags = @()
        foreach ($node in $overview.nodes | Where-Object { $_.role -eq "STANDBY" }) {
            if ($node.replication_lag) {
                $replicaLags += $node.replication_lag
                Write-Status "Node $($node.name): lag = $($node.replication_lag) bytes" "INFO"
            }
        }
        
        # Check if gap is minimal (< 1MB is acceptable for promotion)
        $maxLag = if ($replicaLags.Count -gt 0) { 
            [Math]::Max($replicaLags)
        } else { 
            0 
        }
        
        if ($maxLag -gt 1048576) {  # 1MB threshold
            Write-Status "Replication lag ($maxLag bytes) exceeds acceptable threshold (1MB)" "WARN"
            return $false
        }
        else {
            Write-Status "Replication lag is acceptable ($maxLag bytes < 1MB)" "OK"
            return $true
        }
    }
    catch {
        Write-Status "Error checking replication lag: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Set-NodePrimary {
    param([string]$Node, [int]$StepNum)
    
    Write-Step "Promoting $Node to PRIMARY" $StepNum 7
    
    try {
        # Get current primary before attempting promotion
        $status = Get-ClusterStatus
        $currentPrimary = if ($status) { Get-PrimaryNode -Status $status } else { "UNKNOWN" }
        
        # Check replication gap if we have a known primary
        if ($currentPrimary -ne "UNKNOWN" -and $currentPrimary -ne "NONE" -and $currentPrimary -ne $Node) {
            Write-Status "Current primary: $currentPrimary" "INFO"
            $lagOK = Get-ReplicationLag -CurrentPrimary $currentPrimary -NewPrimary $Node
            if (-not $lagOK) {
                Write-Status "Replication gap check failed. Promotion may result in data loss." "ERROR"
                return $false
            }
        }
        
        Write-Status "Sending promotion request..." "INFO"
        $response = Invoke-WebRequest -Uri "$API_URL/promote/$Node" `
            -Method POST -UseBasicParsing -TimeoutSec 180 `
            -ErrorAction Continue 2>&1
        
        Write-Status "Request sent (may timeout, operation continues)" "OK"
        Write-Status "Waiting 40 seconds for promotion to complete..." "INFO"
        Start-Sleep -Seconds 40
        
        # Verify promotion
        $status = Get-ClusterStatus
        if ($status) {
            $primary = Get-PrimaryNode -Status $status
            if ($primary -eq $Node) {
                Write-Status "$Node is now PRIMARY" "OK"
                return $true
            }
            else {
                Write-Status "Primary is $primary, expected $Node" "WARN"
                return $false
            }
        }
        return $false
    }
    catch {
        Write-Status "Error during promotion: $($_.Exception.Message)" "WARN"
        return $false
    }
}

function Get-ClusterStatus {
    try {
        $response = Invoke-WebRequest -Uri "$API_URL/status" `
            -UseBasicParsing -TimeoutSec 30
        return $response.Content | ConvertFrom-Json
    }
    catch {
        Write-Status "Failed to retrieve status: $($_.Exception.Message)" "ERROR"
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

function Wait-ForPrimaryNode {
    param([int]$MaxRetries = 12, [int]$RetryDelaySeconds = 5)
    
    Write-Status "Waiting for primary node to be elected..." "INFO"
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            $status = Get-ClusterStatus
            if ($status) {
                $primary = Get-PrimaryNode -Status $status
                if ($primary -ne "NONE") {
                    Write-Status "Primary node detected: $primary" "OK"
                    return $primary
                }
            }
        }
        catch {
            Write-Status "Error checking for primary (attempt $i/$MaxRetries): $($_.Exception.Message)" "WARN"
        }
        
        if ($i -lt $MaxRetries) {
            Write-Status "No primary found, retrying in $RetryDelaySeconds seconds... (attempt $i/$MaxRetries)" "WARN"
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    
    Write-Status "No primary node detected after $($MaxRetries * $RetryDelaySeconds) seconds, will attempt manual promotion" "WARN"
    return "NONE"
}

function Show-ClusterStatus {
    Write-Host "   Current Cluster State:" -ForegroundColor Gray
    $status = Get-ClusterStatus
    if ($status) {
        $primary = Get-PrimaryNode -Status $status
        Write-Host "      Primary: $primary" -ForegroundColor Yellow
        foreach ($node in $NODES) {
            $isPrimary = $status.nodes.$node.is_primary
            $role = if ($isPrimary) { "[PRIMARY]" } else { "[STANDBY]" }
            Write-Host "      $node : $role" -ForegroundColor Gray
        }
    }
}

function Initialize-Database {
    Write-Step "Initializing Database with Test Data" 3 7
    
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
    
    $container_map = @{
        "node1" = "postgres-node1"
        "node2" = "postgres-node2"
        "node3" = "postgres-node3"
    }
    
    $container = $container_map[$Node]
    
    try {
        $result = & docker exec $container psql -U $DB_USER -d $DB_NAME `
            -c "SELECT COUNT(*) FROM messages;" 2>&1 | Select-String -Pattern "^\s*\d+\s*$"
        
        if ($result) {
            $count = [int]($result.ToString().Trim())
            return $count
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
    Write-Step "Starting Test Data Generator" 5 7
    
    try {
        Write-Status "Running test data generator (300 seconds)..." "INFO"
        
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
    Write-Step "Validating Data Replication" 6 7
    
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
                    Write-Status "Replication inconsistency: $n1 vs $n2" "WARN"
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

# ============================================================================
# MAIN TEST SEQUENCE
# ============================================================================

Write-Section "COMPREHENSIVE POSTGRESQL CLUSTER TEST"

# Initial cleanup: Remove ALL containers
Clean-AllDockerContainers

# Start containers fresh
Write-Host "`n[STARTUP] Starting Docker containers..." -ForegroundColor Cyan
& docker-compose up -d 2>&1 | Out-Null
Write-Status "Waiting 60 seconds for containers to be ready..." "INFO"
Start-Sleep -Seconds 60

# Step 1: Validate containers
if (-not (Test-AllContainersHealthy)) {
    Write-Status "Some containers are not healthy. Please fix before continuing." "ERROR"
}

# Step 1.5: Wait for any primary to be elected
$currentPrimary = Wait-ForPrimaryNode
if ($currentPrimary -eq "NONE") {
    Write-Status "No primary node elected. Attempting to set node2 as primary..." "WARN"
}

# Step 2: Set node2 as primary
Set-NodePrimary -Node "node2" -StepNum 2
Show-ClusterStatus

# Step 3: Initialize database
Initialize-Database
Show-ClusterStatus

# Step 4: Validate initial entry count
$countsBeforeData = Validate-EntryCount "Before Test Data Generation"

# Step 5: Start test data generator
Start-TestDataGenerator

# Step 6: Validate entry count after data generation
$countsAfterData = Validate-EntryCount "After Test Data Generation"
if ($countsAfterData -and $countsBeforeData) {
    $dataInserted = $countsAfterData["node2"] - $countsBeforeData["node2"]
    Write-Status "Approximately $dataInserted entries inserted during test" "OK"
    
    # Verify data exists
    if ($dataInserted -le 0) {
        Write-Status "No data was inserted - test may have failed" "ERROR"
    }
}

# Step 7: Change primary to node1
Set-NodePrimary -Node "node1" -StepNum 7
Show-ClusterStatus

# Step 8: Validate data replication and consistency
Validate-DataReplication

# Final verification: Check all nodes have data
Write-Host "`n[FINAL CHECK] Verifying data exists on all nodes..." -ForegroundColor Cyan
$allNodesHaveData = $true
foreach ($node in $NODES) {
    $count = Get-EntryCount -Node $node
    if ($count -le 0) {
        Write-Status "$node has NO data - CRITICAL!" "ERROR"
        $allNodesHaveData = $false
    }
    else {
        Write-Status "$node has $count entries" "OK"
    }
}

if (-not $allNodesHaveData) {
    Write-Status "Not all nodes have data after test completion!" "ERROR"
}

Write-Section "TEST COMPLETE"
if ($script:TestFailed) {
    Write-Status "TEST FAILED - Errors occurred during execution" "ERROR"
}
else {
    Write-Status "All tests completed successfully" "OK"
}
Write-Host "`nTo restart this test, use the instructions in TEST_RESTART.md`n" -ForegroundColor Green
