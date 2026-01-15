#!/usr/bin/env pwsh
<#
.SYNOPSIS
    PostgreSQL Failover script to switch primary node
.DESCRIPTION
    Promotes a specified node (node1, node2, or node3) to primary and reconfigures others as standbys
.PARAMETER NewPrimary
    The target node to promote to primary: node1, node2, or node3
.PARAMETER Force
    Skip confirmation prompt
.EXAMPLE
    .\failover.ps1 -NewPrimary node2
    .\failover.ps1 -NewPrimary node3 -Force
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("node1", "node2", "node3")]
    [string]$NewPrimary,
    [switch]$Force = $false
)

$ErrorActionPreference = "Stop"
$workingDir = "C:\Users\reven\docker\postgreSQL"

# Configuration
$DB_USER = "testadmin"
$DB_PASSWORD = "securepwd123"
$DB_NAME = "testdb"
$NODES = @("node1", "node2", "node3")

# Map node names to container names and ports
$NodeConfig = @{
    "node1" = @{Container = "postgres-node1"; Port = 5432; Volume = "postgres_primary_data"; MainPort = "5432"}
    "node2" = @{Container = "postgres-node2"; Port = 5435; Volume = "postgres_node2_data"; MainPort = "5435"}
    "node3" = @{Container = "postgres-node3"; Port = 5436; Volume = "postgres_node3_data"; MainPort = "5436"}
}

function Write-Header {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Error-Custom {
    param([string]$Message)
    Write-Host "❌ $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Cyan
}

function Test-Node-Health {
    param([string]$NodeName)
    $Config = $NodeConfig[$NodeName]
    $Container = $Config.Container
    
    Write-Info "Testing health of $NodeName ($Container)..."
    $Status = docker exec $Container pg_isready -U $DB_USER 2>$null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Success "$NodeName is healthy"
        return $true
    } else {
        Write-Error-Custom "$NodeName is not healthy"
        return $false
    }
}

function Get-Current-Primary {
    foreach ($Node in $NODES) {
        $Container = $NodeConfig[$Node].Container
        
        # Check if this node has the main database
        $HasDB = docker exec $Container psql -U $DB_USER -d $DB_NAME -c "SELECT 1" 2>$null
        $isInRecovery = docker exec -e PGPASSWORD=$DB_PASSWORD $Container psql -U $DB_USER -d postgres -c "SELECT pg_is_in_recovery();" 2>&1 | Select-String "f"
        
        if ($HasDB -and $isInRecovery) {
            return $Node
        }
    }
    return $null
}

function Promote-Node {
    param([string]$NodeName)
    $Config = $NodeConfig[$NodeName]
    $Container = $Config.Container
    
    Write-Info "Promoting $NodeName ($Container) to PRIMARY..."
    
    # Resume WAL replay and promote
    docker exec $Container bash -c "rm -f /var/lib/postgresql/data/pgdata/standby.signal" 2>$null
    docker exec -e PGPASSWORD=$DB_PASSWORD $Container psql -U $DB_USER -d postgres -c "SELECT pg_wal_replay_resume();" 2>$null
    
    Start-Sleep -Seconds 2
    
    docker exec $Container pg_ctl promote -D /var/lib/postgresql/data/pgdata 2>$null
    Write-Success "Promotion command sent to $NodeName"
    
    Start-Sleep -Seconds 5
    
    # Verify promotion
    $isInRecovery = docker exec -e PGPASSWORD=$DB_PASSWORD $Container psql -U $DB_USER -d postgres -c "SELECT pg_is_in_recovery();" 2>&1 | Select-String "f"
    if ($isInRecovery) {
        Write-Success "$NodeName is now PRIMARY"
        return $true
    } else {
        Write-Error-Custom "Promotion of $NodeName may have failed"
        return $false
    }
}

function Reconfigure-Standby {
    param([string]$NodeName, [string]$PrimaryNode)
    $Config = $NodeConfig[$NodeName]
    $Container = $Config.Container
    $PrimaryConfig = $NodeConfig[$PrimaryNode]
    $PrimaryContainer = $PrimaryConfig.Container
    
    Write-Info "Reconfiguring $NodeName as standby (replicating from $PrimaryNode)..."
    
    # Stop the standby node
    docker stop $Container 2>$null
    Start-Sleep -Seconds 2
    
    # Clear data directory
    docker exec $Container bash -c "rm -rf /var/lib/postgresql/data/pgdata/*" 2>$null
    
    # Create base backup from new primary
    Write-Info "Creating base backup from $PrimaryNode..."
    docker exec $Container bash -c "PGPASSWORD=$DB_PASSWORD pg_basebackup -h $PrimaryContainer -U $DB_USER -D /var/lib/postgresql/data/pgdata -P -R" 2>$null
    
    # Create standby signal
    docker exec $Container bash -c "touch /var/lib/postgresql/data/pgdata/standby.signal" 2>$null
    
    # Start the container
    docker start $Container 2>$null
    Start-Sleep -Seconds 5
    
    if (Test-Node-Health $NodeName) {
        Write-Success "$NodeName is now STANDBY (replicating from $PrimaryNode)"
        return $true
    } else {
        Write-Error-Custom "Failed to reconfigure $NodeName as standby"
        return $false
    }
}

# Main failover logic
Write-Header "PostgreSQL Failover Script - Multi-Node Support"
Write-Host "Target Action: Promote $NewPrimary to PRIMARY`n"

# Validate new primary is in the list
if ($NewPrimary -notin $NODES) {
    Write-Error-Custom "Invalid node: $NewPrimary. Must be one of: $($NODES -join ', ')"
    exit 1
}

# Step 1: Find current primary
Write-Header "STEP 1: Identify Current Primary"
$CurrentPrimary = Get-Current-Primary
if (!$CurrentPrimary) {
    Write-Error-Custom "Could not determine current primary node"
    exit 1
}
Write-Success "Current primary is: $CurrentPrimary"

if ($CurrentPrimary -eq $NewPrimary) {
    Write-Error-Custom "$NewPrimary is already the primary node. Aborting."
    exit 1
}

# Step 2: Health check
Write-Header "STEP 2: Pre-Failover Health Check"
foreach ($Node in $NODES) {
    Test-Node-Health $Node | Out-Null
}

# Step 3: Verify new primary is healthy
Write-Header "STEP 3: Verify New Primary Node ($NewPrimary)"
if (!(Test-Node-Health $NewPrimary)) {
    Write-Error-Custom "New primary node is not healthy. Aborting failover."
    exit 1
}

# Step 4: Confirmation
Write-Header "STEP 4: Failover Summary"
Write-Host "Current PRIMARY:  $CurrentPrimary ($($NodeConfig[$CurrentPrimary].Container):$($NodeConfig[$CurrentPrimary].Port))"
Write-Host "New PRIMARY:      $NewPrimary ($($NodeConfig[$NewPrimary].Container):$($NodeConfig[$NewPrimary].Port))"
$Others = $NODES | Where-Object { $_ -ne $CurrentPrimary -and $_ -ne $NewPrimary }
Write-Host "Standby Nodes:    $($Others -join ', ')"
Write-Host ""

if (!$Force) {
    $Confirm = Read-Host "Proceed with failover? (type 'yes' to confirm)"
    if ($Confirm -ne "yes") {
        Write-Error-Custom "Failover cancelled by user"
        exit 1
    }
}

# Step 5: Promote new primary
Write-Header "STEP 5: Promote $NewPrimary to Primary"
if (!(Promote-Node $NewPrimary)) {
    Write-Error-Custom "Failed to promote $NewPrimary. Aborting."
    exit 1
}

Start-Sleep -Seconds 3

# Step 6: Reconfigure standby nodes
Write-Header "STEP 6: Reconfigure Standby Nodes"
foreach ($Node in $NODES) {
    if ($Node -eq $NewPrimary) { continue }
    
    if (!(Reconfigure-Standby $Node $NewPrimary)) {
        Write-Warning "Some issues reconfiguring $Node - continuing..."
    }
    Start-Sleep -Seconds 2
}

# Step 7: Final health check
Write-Header "STEP 7: Post-Failover Health Check"
foreach ($Node in $NODES) {
    Test-Node-Health $Node | Out-Null
}

# Step 8: Display replication status
Write-Header "STEP 8: Replication Status"
Write-Info "Checking replication from new primary ($NewPrimary):"
$PrimaryContainer = $NodeConfig[$NewPrimary].Container
docker exec -e PGPASSWORD=$DB_PASSWORD $PrimaryContainer psql -U $DB_USER -d postgres -c "SELECT client_addr, state, sync_state FROM pg_stat_replication;" 2>$null

# Summary
Write-Header "Failover Complete!"
Write-Success "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""
Write-Host "NEW TOPOLOGY:" -ForegroundColor Green
foreach ($Node in $NODES) {
    $Config = $NodeConfig[$Node]
    if ($Node -eq $NewPrimary) {
        Write-Host "  $($Config.Container):$($Config.Port) ← PRIMARY" -ForegroundColor Green
    } else {
        Write-Host "  $($Config.Container):$($Config.Port) ← STANDBY" -ForegroundColor Cyan
    }
}
Write-Host ""
Write-Host "UPDATE CONNECTION STRINGS:" -ForegroundColor Yellow
$NewPrimaryConfig = $NodeConfig[$NewPrimary]
Write-Host "  postgresql://$DB_USER:$DB_PASSWORD@$($NodeConfig[$NewPrimary].Container):$($NewPrimary -eq 'node1' ? 5432 : ($NewPrimary -eq 'node2' ? 5435 : 5436))/$DB_NAME" -ForegroundColor Yellow
Write-Host ""
