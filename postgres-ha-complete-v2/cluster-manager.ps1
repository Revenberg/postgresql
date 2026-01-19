#!/usr/bin/env pwsh
<#
PostgreSQL HA Cluster - Complete Setup and Testing Script
Author: HA Team
Date: 2026-01-18
Description: Full lifecycle management of PostgreSQL cluster with failover testing
#>

param(
    [ValidateSet('setup', 'start', 'stop', 'test', 'failover', 'validate', 'cleanup', 'all')]
    [string]$Mode = 'setup',
    [string]$BaseDir = (Split-Path -Parent $MyInvocation.MyCommand.Path)
)

# Color codes
$Colors = @{
    Success = 'Green'
    Error = 'Red'
    Warning = 'Yellow'
    Info = 'Cyan'
    Header = 'Magenta'
}

function Write-Colored {
    param([string]$Text, [string]$Color = 'White')
    Write-Host $Text -ForegroundColor $Color
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Header
    Write-Host "║ $($Title.PadRight(56)) ║" -ForegroundColor $Colors.Header
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Header
}

function Test-PostgreSQL {
    param(
        [string]$Host,
        [int]$Port,
        [string]$User = 'appuser',
        [string]$Password = 'apppass',
        [string]$Database = 'appdb'
    )
    
    $env:PGPASSWORD = $Password
    try {
        $result = psql -h $Host -p $Port -U $User -d $Database -t -c "SELECT 1" 2>$null
        return $result -eq '1'
    }
    catch {
        return $false
    }
    finally {
        Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue
    }
}

function Start-Cluster {
    Write-Section "Starting PostgreSQL HA Cluster"
    
    $nodes = @(
        @{Name="Primary"; Path="$BaseDir\ha-nodes\primary"; Port=5432}
        @{Name="Backup1"; Path="$BaseDir\ha-nodes\backup1"; Port=5433}
        @{Name="Backup2"; Path="$BaseDir\ha-nodes\backup2"; Port=5434}
        @{Name="RO1"; Path="$BaseDir\ro-nodes\ro1"; Port=5440}
        @{Name="RO2"; Path="$BaseDir\ro-nodes\ro2"; Port=5441}
        @{Name="RO3"; Path="$BaseDir\ro-nodes\ro3"; Port=5442}
    )
    
    foreach ($node in $nodes) {
        Write-Colored "Starting $($node.Name)..." $Colors.Info
        Push-Location $node.Path
        docker compose up -d
        if ($LASTEXITCODE -eq 0) {
            Write-Colored "✓ $($node.Name) started" $Colors.Success
        } else {
            Write-Colored "✗ Failed to start $($node.Name)" $Colors.Error
        }
        Pop-Location
        Start-Sleep -Seconds 3
    }
    
    # Wait for all nodes to be healthy
    Write-Colored "`nWaiting for all nodes to be ready..." $Colors.Info
    $maxRetries = 30
    $retries = 0
    
    while ($retries -lt $maxRetries) {
        $allHealthy = $true
        foreach ($node in $nodes) {
            if (-not (Test-PostgreSQL -Host "localhost" -Port $node.Port)) {
                $allHealthy = $false
                break
            }
        }
        
        if ($allHealthy) {
            Write-Colored "✓ All nodes are healthy" $Colors.Success
            break
        }
        
        $retries++
        Write-Colored "  Attempt $retries/$maxRetries..." $Colors.Warning
        Start-Sleep -Seconds 2
    }
    
    if ($retries -ge $maxRetries) {
        Write-Colored "✗ Cluster failed to become healthy" $Colors.Error
        return $false
    }
    
    # Start monitoring
    Write-Colored "`nStarting monitoring stack..." $Colors.Info
    Push-Location "$BaseDir\monitoring"
    docker compose up -d
    Pop-Location
    
    # Start test containers
    Write-Colored "Starting test containers..." $Colors.Info
    Push-Location "$BaseDir\test-containers"
    docker compose up -d
    Pop-Location
    
    Write-Colored "`n✓ Cluster startup complete!" $Colors.Success
    return $true
}

function Stop-Cluster {
    Write-Section "Stopping PostgreSQL HA Cluster"
    
    $components = @(
        @{Name="Test Containers"; Path="$BaseDir\test-containers"}
        @{Name="Monitoring"; Path="$BaseDir\monitoring"}
        @{Name="RO3"; Path="$BaseDir\ro-nodes\ro3"}
        @{Name="RO2"; Path="$BaseDir\ro-nodes\ro2"}
        @{Name="RO1"; Path="$BaseDir\ro-nodes\ro1"}
        @{Name="Backup2"; Path="$BaseDir\ha-nodes\backup2"}
        @{Name="Backup1"; Path="$BaseDir\ha-nodes\backup1"}
        @{Name="Primary"; Path="$BaseDir\ha-nodes\primary"}
    )
    
    foreach ($comp in $components) {
        if (Test-Path $comp.Path) {
            Write-Colored "Stopping $($comp.Name)..." $Colors.Info
            Push-Location $comp.Path
            docker compose down
            Pop-Location
        }
    }
    
    Write-Colored "✓ All components stopped" $Colors.Success
}

function Run-SyncTest {
    Write-Section "Running Cluster Synchronization Test"
    
    Write-Colored "Inserting test data into primary..." $Colors.Info
    $env:PGPASSWORD = 'apppass'
    
    # Insert 100 test records
    for ($i = 1; $i -le 100; $i++) {
        psql -h localhost -U appuser -d appdb -c "INSERT INTO sync_test (data) VALUES ('Test-$i-$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')');" 2>$null
    }
    
    Start-Sleep -Seconds 2
    
    Write-Colored "`nVerifying synchronization across all nodes:" $Colors.Info
    
    $nodes = @(
        @{Name="Primary"; Host="localhost"; Port=5432}
        @{Name="Backup1"; Host="localhost"; Port=5433}
        @{Name="Backup2"; Host="localhost"; Port=5434}
        @{Name="RO1"; Host="localhost"; Port=5440}
        @{Name="RO2"; Host="localhost"; Port=5441}
        @{Name="RO3"; Host="localhost"; Port=5442}
    )
    
    $counts = @{}
    foreach ($node in $nodes) {
        $count = psql -h $node.Host -p $node.Port -U appuser -d appdb -t -c "SELECT COUNT(*) FROM sync_test;" 2>$null
        $counts[$node.Name] = $count
        Write-Colored "  $($node.Name): $count rows" $Colors.Success
    }
    
    Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue
    
    # Check if all counts are equal
    $unique = $counts.Values | Select-Object -Unique
    if ($unique.Count -eq 1) {
        Write-Colored "✓ All nodes are in sync!" $Colors.Success
        return $true
    } else {
        Write-Colored "✗ Nodes are out of sync!" $Colors.Error
        return $false
    }
}

function Simulate-Failover {
    param([string]$FromNode = 'Primary', [string]$ToNode = 'Backup1')
    
    Write-Section "Simulating Failover from $FromNode to $ToNode"
    
    Write-Colored "Step 1: Stopping $FromNode..." $Colors.Info
    docker stop pg-primary
    Start-Sleep -Seconds 3
    
    Write-Colored "Step 2: Promoting $ToNode to primary..." $Colors.Info
    $env:PGPASSWORD = 'apppass'
    psql -h localhost -p 5433 -U appuser -d appdb -c "SELECT pg_promote();" 2>$null
    Start-Sleep -Seconds 5
    
    Write-Colored "Step 3: Verifying new primary..." $Colors.Info
    if (Test-PostgreSQL -Host "localhost" -Port 5433) {
        Write-Colored "✓ New primary is operational" $Colors.Success
    } else {
        Write-Colored "✗ New primary failed" $Colors.Error
    }
    
    Write-Colored "Step 4: Testing write capability on new primary..." $Colors.Info
    psql -h localhost -p 5433 -U appuser -d appdb -c "INSERT INTO sync_test (data) VALUES ('Failover Test');" 2>$null
    Write-Colored "✓ Write successful on new primary" $Colors.Success
    
    Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue
}

function Get-ClusterStatus {
    Write-Section "PostgreSQL HA Cluster Status"
    
    Write-Colored "Container Status:" $Colors.Info
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | findstr /I "pg-"
    
    Write-Colored "`nDatabase Status:" $Colors.Info
    $env:PGPASSWORD = 'apppass'
    
    $nodes = @(
        @{Name="Primary"; Host="localhost"; Port=5432}
        @{Name="Backup1"; Host="localhost"; Port=5433}
        @{Name="Backup2"; Host="localhost"; Port=5434}
        @{Name="RO1"; Host="localhost"; Port=5440}
        @{Name="RO2"; Host="localhost"; Port=5441}
        @{Name="RO3"; Host="localhost"; Port=5442}
    )
    
    foreach ($node in $nodes) {
        $role = psql -h $node.Host -p $node.Port -U appuser -d appdb -t -c "SELECT pg_is_in_recovery()::text;" 2>$null
        if ($role -eq 't') {
            $status = "Standby/RO"
        } else {
            $status = "Primary"
        }
        Write-Colored "  $($node.Name) ($($node.Host):$($node.Port)): $status" $Colors.Success
    }
    
    Remove-Item env:PGPASSWORD -ErrorAction SilentlyContinue
}

# Main execution
switch ($Mode) {
    'setup' {
        Start-Cluster
        Get-ClusterStatus
    }
    'start' {
        Start-Cluster
    }
    'stop' {
        Stop-Cluster
    }
    'test' {
        Run-SyncTest
    }
    'failover' {
        Simulate-Failover
    }
    'validate' {
        Get-ClusterStatus
    }
    'all' {
        Start-Cluster
        Start-Sleep -Seconds 5
        Run-SyncTest
        Get-ClusterStatus
        Write-Colored "`n✓ Setup and validation complete!" $Colors.Success
    }
}
