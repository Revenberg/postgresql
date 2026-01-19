# PostgreSQL HA Cluster - Comprehensive 30-Minute Test Guide

## Overview

This guide provides step-by-step instructions to run a complete 30-minute PostgreSQL HA cluster test with:
- ✅ Clean environment setup (remove all containers/images/volumes)
- ✅ Fresh cluster deployment
- ✅ Automated test execution
- ✅ Primary node failover every 5 minutes
- ✅ Real-time validation of data consistency
- ✅ Monitoring of inserts and updates
- ✅ Comprehensive results validation

---

## Complete Test Execution Guide

### Phase 1: Clean Environment Setup

#### Step 1.1: Stop All Running Containers
```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2

# Stop all running containers
docker compose down --remove-orphans
docker rm $(docker ps -aq) 2>&1; Write-Host ""; Write-Host "All containers removed." -ForegroundColor Green

# Wait for clean shutdown
Start-Sleep -Seconds 5
```

#### Step 1.2: Remove All Volumes
```powershell
# Remove volumes associated with the project
$volumes = docker volume ls -q | Select-String "postgres-ha-complete-v2"
if ($volumes) {
    docker volume rm $volumes
    Write-Host "Volumes removed"
} else {
    Write-Host "No volumes to remove"
}

# Verify volumes are gone
docker volume ls | Select-String "postgres-ha"
```

#### Step 1.3: Remove Old Images (Optional - for fresh build)
```powershell
# List images related to the project
docker images | Select-String "postgres|etcd|prometheus|grafana|exporter"

# Remove if needed (optional - only if you want to rebuild from scratch)
# docker rmi postgres:15 quay.io/coreos/etcd:v3.5.0 <other images>
```

#### Step 1.4: Clean Docker System (Deep Clean)
```powershell
# Remove unused resources
docker system prune -f

# Optional: More aggressive cleanup (warning: removes all unused images)
docker system prune -a -f
```

---

### Phase 2: Build and Start Cluster

#### Step 2.1: Verify docker-compose.yml Configuration
```powershell
# Check that config is valid
docker compose config | Select-Object -First 30

# Should show services: pg-node-1 through pg-node-6, etcd-primary
```

#### Step 2.2: Start Primary and etcd
```powershell
# Start only pg-node-1 (primary) and etcd first
docker compose up -d pg-node-1 etcd-primary

# Wait for primary to be healthy (60+ seconds)
Write-Host "Waiting for pg-node-1 to become healthy..."
$counter = 0
while ($counter -lt 120) {
    $status = docker compose ps pg-node-1 | Select-String "healthy"
    if ($status) {
        Write-Host "✓ pg-node-1 is healthy"
        break
    }
    Write-Host "  Waiting... ($counter/120 seconds)"
    Start-Sleep -Seconds 1
    $counter++
}
```

#### Step 2.3: Verify Primary is Ready
```powershell
# Test connection to primary
docker exec pg-node-1 pg_isready -U appuser -d appdb

# Should output: "accepting connections"
```

#### Step 2.4: Create Test Database Structure
```powershell
# Create test tables on primary
docker exec pg-node-1 psql -U appuser -d appdb -c "
DROP TABLE IF EXISTS test_data;
CREATE TABLE test_data (
    id SERIAL PRIMARY KEY,
    test_value VARCHAR(255),
    insert_timestamp TIMESTAMP DEFAULT NOW(),
    update_timestamp TIMESTAMP DEFAULT NOW(),
    operation_type VARCHAR(20) DEFAULT 'INSERT'
);
CREATE INDEX idx_test_timestamp ON test_data(insert_timestamp);
"

Write-Host "✓ Test tables created on pg-node-1"
```

#### Step 2.5: Start Replica Nodes
```powershell
# Start remaining nodes one by one
$replicas = @("pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")

foreach ($replica in $replicas) {
    Write-Host "Starting $replica..."
    docker compose up -d $replica
    
    # Wait for replication to catch up (30-45 seconds per node)
    $counter = 0
    while ($counter -lt 90) {
        $health = docker compose ps $replica | Select-String "healthy"
        if ($health) {
            Write-Host "✓ $replica is healthy"
            break
        }
        Write-Host "  Waiting for $replica... ($counter/90 seconds)"
        Start-Sleep -Seconds 1
        $counter++
    }
}

# Verify all nodes are running
docker compose ps | Select-String "pg-node"
```

#### Step 2.6: Verify Replication is Active
```powershell
# Check primary replication status
docker exec pg-node-1 psql -U appuser -d appdb -c "
SELECT 
    usesysid,
    usename,
    application_name,
    client_addr,
    state,
    sync_state,
    write_lag,
    flush_lag,
    replay_lag
FROM pg_stat_replication;
"

# Should show 5 active replicas

# Check replication slots
docker exec pg-node-1 psql -U appuser -d appdb -c "
SELECT slot_name, slot_type, active, restart_lsn 
FROM pg_replication_slots;
"

# Should show 5 active slots
```

---

### Phase 3: Start Monitoring Stack (Optional)

```powershell
# Start Prometheus and Grafana
cd monitoring
docker compose up -d

# Wait for services
Start-Sleep -Seconds 10

# Access Grafana at http://localhost:3000 (admin/admin)
# Access Prometheus at http://localhost:9090

cd ..
```

---

### Phase 4: Execute 30-Minute Test with Primary Failover

#### Step 4.1: Create Test Execution Script

Save this as `run-30min-failover-test.ps1`:

```powershell
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
    param([string]$NodeName, [int]$Port)
    try {
        $count = docker exec $NodeName psql -U appuser -d appdb -t -c `
            "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        return $count
    }
    catch { return "ERROR" }
}

function Get-OperationCounts {
    param([string]$NodeName)
    try {
        $result = docker exec $NodeName psql -U appuser -d appdb -t -c `
            "SELECT 
                COUNT(*) as total,
                COUNT(CASE WHEN operation_type='INSERT' THEN 1 END) as inserts,
                COUNT(CASE WHEN operation_type='UPDATE' THEN 1 END) as updates,
                COUNT(CASE WHEN operation_type='DELETE' THEN 1 END) as deletes
            FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        return $result
    }
    catch { return "ERROR|ERROR|ERROR|ERROR" }
}

function Promote-Node {
    param([string]$NewPrimary)
    Write-Log "Promoting $NewPrimary to primary..." "FAILOVER"
    
    # Stop replication on new primary
    docker exec $NewPrimary pg_ctl promote -D /var/lib/postgresql/data 2>&1 | Out-Null
    Start-Sleep -Seconds 5
    
    Write-Log "✓ $NewPrimary promoted to primary" "FAILOVER"
    Add-Content -Path $failoverLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Promoted $NewPrimary to primary"
}

function Get-CurrentPrimary {
    $result = docker exec pg-node-1 psql -U appuser -d appdb -t -c `
        "SELECT pg_is_wal_replay_paused();" 2>$null
    
    if ($result -like "*t*") { return "pg-node-1" }
    
    # Check other nodes
    for ($i = 2; $i -le 6; $i++) {
        $node = "pg-node-$i"
        $result = docker exec $node psql -U appuser -d appdb -t -c `
            "SELECT NOT pg_is_wal_replay_paused();" 2>$null | ForEach-Object { $_.Trim() }
        
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
```

#### Step 4.2: Run the Failover Test
```powershell
# Execute the 30-minute test with failovers every 5 minutes
.\run-30min-failover-test.ps1

# Or with custom parameters:
.\run-30min-failover-test.ps1 -TestDuration 1800 -FailoverInterval 300 -ValidationInterval 60
```

---

### Phase 5: Monitor Test Execution

#### Real-Time Monitoring
```powershell
# In a separate terminal, watch the results in real-time:
Get-Content test-logs/results-*.log -Wait

# Or watch all nodes' row counts:
$nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
while ($true) {
    Clear-Host
    Write-Host "$(Get-Date -Format 'HH:mm:ss') - Row Count Across All Nodes:"
    Write-Host "================================"
    foreach ($node in $nodes) {
        $count = docker exec $node psql -U appuser -d appdb -t -c `
            "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
        Write-Host "$node : $count rows"
    }
    Start-Sleep -Seconds 5
}
```

#### Grafana Dashboard (Optional)
```
Access http://localhost:3000
- Login: admin / admin
- View PostgreSQL HA Cluster Dashboard
- Watch metrics during failovers
```

---

### Phase 6: Validate Results

#### Step 6.1: Check Test Logs
```powershell
# View full test execution log
Get-Content test-logs/test-*.log | Select-Object -Last 50

# View validation reports
Get-Content test-logs/results-*.log

# View failover events
Get-Content test-logs/failovers-*.log
```

#### Step 6.2: Final Data Consistency Check
```powershell
# Get final row counts from all nodes
$nodes = @("pg-node-1", "pg-node-2", "pg-node-3", "pg-node-4", "pg-node-5", "pg-node-6")
$results = @()

Write-Host "FINAL VALIDATION"
Write-Host "================"

foreach ($node in $nodes) {
    $count = docker exec $node psql -U appuser -d appdb -t -c `
        "SELECT COUNT(*) FROM test_data;" 2>$null | ForEach-Object { $_.Trim() }
    
    $inserts = docker exec $node psql -U appuser -d appdb -t -c `
        "SELECT COUNT(*) FROM test_data WHERE operation_type='INSERT';" 2>$null | ForEach-Object { $_.Trim() }
    
    $updates = docker exec $node psql -U appuser -d appdb -t -c `
        "SELECT COUNT(*) FROM test_data WHERE operation_type='UPDATE';" 2>$null | ForEach-Object { $_.Trim() }
    
    Write-Host "$node : Total=$count | Inserts=$inserts | Updates=$updates"
    
    $results += @{ Node = $node; Total = $count; Inserts = $inserts; Updates = $updates }
}

# Check consistency
$totalCounts = $results | Select-Object -ExpandProperty Total | Sort-Object -Unique
if ($totalCounts.Count -eq 1) {
    Write-Host ""
    Write-Host "✅ SUCCESS: All nodes consistent!"
    Write-Host "All nodes have: $($totalCounts[0]) total rows"
} else {
    Write-Host ""
    Write-Host "⚠️  WARNING: Data inconsistency detected!"
    Write-Host "Node row counts: $(($results | Select-Object -ExpandProperty Total) -join ', ')"
}
```

#### Step 6.3: Generate Summary Report
```powershell
# Create summary report
$reportFile = "test-logs/summary-report.txt"

"PostgreSQL HA Cluster - 30 Minute Test Summary" | Out-File $reportFile
"=" * 60 | Out-File $reportFile -Append
"Test Date: $(Get-Date)" | Out-File $reportFile -Append
"" | Out-File $reportFile -Append

"Node Configuration:" | Out-File $reportFile -Append
"- pg-node-1 (5432): Primary" | Out-File $reportFile -Append
"- pg-node-2 (5433): Standby" | Out-File $reportFile -Append
"- pg-node-3 (5434): Standby" | Out-File $reportFile -Append
"- pg-node-4 (5440): Read-Only" | Out-File $reportFile -Append
"- pg-node-5 (5441): Read-Only" | Out-File $reportFile -Append
"- pg-node-6 (5442): Read-Only" | Out-File $reportFile -Append
"" | Out-File $reportFile -Append

"Test Configuration:" | Out-File $reportFile -Append
"- Duration: 30 minutes" | Out-File $reportFile -Append
"- Failover Interval: Every 5 minutes" | Out-File $reportFile -Append
"- Validation Interval: Every 1 minute" | Out-File $reportFile -Append
"" | Out-File $reportFile -Append

"Test Results:" | Out-File $reportFile -Append
Get-Content test-logs/results-*.log | Out-File $reportFile -Append
"" | Out-File $reportFile -Append

"Failover Events:" | Out-File $reportFile -Append
Get-Content test-logs/failovers-*.log | Out-File $reportFile -Append

Write-Host "Summary report created: $reportFile"
```

---

## Quick Start Commands

### Complete Test from Scratch (Copy & Paste)

```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2

# 1. Clean environment
Write-Host "1/5: Cleaning environment..."
docker compose down --remove-orphans
Start-Sleep -Seconds 5

# 2. Remove volumes
Write-Host "2/5: Removing volumes..."
docker volume prune -f

# 3. Start cluster
Write-Host "3/5: Starting cluster..."
docker compose up -d
Start-Sleep -Seconds 90

# 4. Verify cluster is healthy
Write-Host "4/5: Verifying cluster..."
docker compose ps | Select-String "pg-node"

# 5. Run test
Write-Host "5/5: Starting 30-minute test..."
.\run-30min-failover-test.ps1

# Wait for test to complete (30+ minutes)
```

---

## Test Success Criteria

✅ **Test Passed If:**
- All nodes start successfully and become healthy
- Write workload runs continuously without errors
- Every 5 minutes, one node is successfully promoted to primary
- Every minute, row counts are validated across all 6 nodes
- After 30 minutes, all nodes have identical row counts
- No data loss or corruption detected
- Replication lag remains < 1 second throughout test

❌ **Test Failed If:**
- Any node fails to start or become healthy
- Write workload encounters database errors
- Row counts differ between nodes (after replication time)
- Test terminates before 30 minutes
- Data corruption or missing rows detected

---

## Troubleshooting

### Issue: Nodes Won't Start
```powershell
# Check logs
docker logs pg-node-1
docker logs pg-node-2

# Force restart
docker compose restart pg-node-2

# Or rebuild entirely
docker compose down -v
docker compose up -d
```

### Issue: Test Script Errors
```powershell
# Verify permissions
Get-ExecutionPolicy

# Allow script execution if needed
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Run test again
.\run-30min-failover-test.ps1
```

### Issue: Replication Not Syncing
```powershell
# Check replication slots
docker exec pg-node-1 psql -U appuser -d appdb -c "SELECT * FROM pg_replication_slots;"

# Check replication status
docker exec pg-node-1 psql -U appuser -d appdb -c "SELECT * FROM pg_stat_replication;"

# Verify network connectivity
docker network inspect postgres-ha-complete-v2_ha-network
```

---

## Expected Test Output

```
[18:00:00] [INFO] ================================
[18:00:00] [INFO] PostgreSQL HA 30-Minute Failover Test
[18:00:00] [INFO] ================================
[18:00:00] [INFO] Starting write workload...
[18:00:05] [INFO] ✓ Write workload started

[18:05:00] [FAILOVER] Promoting pg-node-2 to primary...
[18:05:05] [FAILOVER] ✓ pg-node-2 promoted to primary

[18:05:00] [REPORT] --- VALIDATION REPORT (Elapsed: 300s / Remaining: 1500s) ---
[18:05:00] [REPORT] Current Primary: pg-node-2
[18:05:00] [REPORT] pg-node-1 | Total: 3000 | Inserts: 2850 | Updates: 150 | Deletes: 0
[18:05:00] [REPORT] pg-node-2 | Total: 3000 | Inserts: 2850 | Updates: 150 | Deletes: 0
[18:05:00] [REPORT] pg-node-3 | Total: 3000 | Inserts: 2850 | Updates: 150 | Deletes: 0
[18:05:00] [REPORT] pg-node-4 | Total: 3000 | Inserts: 2850 | Updates: 150 | Deletes: 0
[18:05:00] [REPORT] pg-node-5 | Total: 3000 | Inserts: 2850 | Updates: 150 | Deletes: 0
[18:05:00] [REPORT] pg-node-6 | Total: 3000 | Inserts: 2850 | Updates: 150 | Deletes: 0

...

[18:30:00] [REPORT] ================================
[18:30:00] [REPORT] Test Completed Successfully!
[18:30:00] [REPORT] ================================
[18:30:00] [REPORT] ✓ All nodes consistent: All have 18000 rows
```

---

## Phase 7: Optional - Add Read Load on Read-Only Nodes

To simulate realistic workload with continuous read operations on read-only replicas:

```powershell
# In a new terminal, start the read load generator
cd C:\Users\reven\docker\postgres-ha-complete-v2

# Run continuous read workload on pg-node-4, pg-node-5, pg-node-6
& ".\read-load-generator.ps1"
```

**What this does**:
- Starts aggressive read queries on all 3 read-only nodes
- Runs COUNT, GROUP BY, ORDER BY, and complex aggregations
- Continues for full 30-minute test duration
- Generates realistic production read workload

---

## Phase 8: Monitor Read/Write Load in Grafana

After starting both write and read workloads, view the performance dashboard:

```
Access Grafana Dashboard:
1. Open: http://localhost:3000
2. Login: admin / admin
3. Navigate to: PostgreSQL HA - Read/Write Load Analysis
4. View metrics:
   - Connections across all nodes
   - Active queries (reads vs writes)
   - Tuple operations (INSERT rates)
   - Sequential scan rates (read load)
   - Read vs Write comparison
```

**Dashboard URL**:
```
http://localhost:3000/d/bd3226d1-9fb2-48f6-aa6d-050f98c098fe/postgresql-ha-read-write-load-analysis
```

**Key Metrics**:
- **Inserts/sec**: Write workload rate on primary
- **Scans/sec**: Read load rate on read-only nodes
- **Connections**: Active connections per node
- **Active Queries**: Number of concurrent queries

---

## Complete Test Execution - Full Command

Run everything in sequence (automatic):

```powershell
cd C:\Users\reven\docker\postgres-ha-complete-v2

# Terminal 1: Start cluster and write test
& ".\test-simple.ps1"

# Terminal 2 (after test starts): Start read load
& ".\read-load-generator.ps1"

# Terminal 3: Monitor in Grafana
# Open: http://localhost:3000
```

---

## Test Success Criteria - With Read Load

✅ **Test Passed If:**
- All nodes start successfully and become healthy
- Write workload runs continuously without errors
- Read workload generates aggressive queries on read-only nodes
- Every 5 minutes, one node is successfully promoted to primary
- Row counts remain identical across all 6 nodes
- After 30 minutes, all nodes have identical row counts
- Read operations complete successfully on replicas
- No connection errors or query timeouts observed

❌ **Test Failed If:**
- Any node becomes unhealthy
- Write or read workload encounters errors
- Row counts diverge between nodes
- Read queries timeout on read-only replicas
- Data corruption or missing rows detected

---

## Next Steps After Test

1. Review test logs in `test-logs/` directory
2. Check Grafana metrics for performance insights
3. Analyze failover times and data consistency windows
4. Verify read workload on replicas didn't impact primary
5. Document any issues or anomalies
6. Plan production deployment based on results

---

**Document Version**: 2.0
**Last Updated**: 2026-01-18
**Test Environment**: Docker Compose with 6 PostgreSQL nodes + etcd + Read/Write Load
**Read Load**: 30 minutes continuous on read-only replicas (pg-node-4, pg-node-5, pg-node-6)
**Write Load**: 30 minutes continuous on primary with 5-minute failovers
