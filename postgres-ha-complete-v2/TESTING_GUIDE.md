# PostgreSQL HA Cluster - Complete Testing Guide

> **Version**: 2.0  
> **Date**: 2026-01-18  
> **Cluster**: 1 Primary + 2 Backups + 3 RO Replicas  

---

## Table of Contents

1. [Deployment](#deployment)
2. [Basic Operations](#basic-operations)
3. [Synchronization Testing](#synchronization-testing)
4. [Failover Testing](#failover-testing)
5. [Monitoring](#monitoring)
6. [Troubleshooting](#troubleshooting)
7. [Automated Test Script](#automated-test-script)

---

## Deployment

### Phase 1: Start Primary Node

```bash
cd c:\Users\reven\docker\postgres-ha-complete-v2\ha-nodes\primary
docker compose up -d

# Verify
docker logs pg-primary | tail -20
docker exec pg-primary psql -U appuser -d appdb -c "\dt"
```

**Expected output**: Tables created (test_replication, cluster_status, sync_test)

### Phase 2: Start Backup Nodes (2 replicas of primary)

```bash
# Backup1
cd c:\Users\reven\docker\postgres-ha-complete-v2\ha-nodes\backup1
docker compose up -d
sleep 10

# Backup2
cd c:\Users\reven\docker\postgres-ha-complete-v2\ha-nodes\backup2
docker compose up -d
sleep 10
```

**Verification**:
```bash
# Check replication status
$env:PGPASSWORD = 'apppass'
psql -h localhost -U appuser -d appdb -c "SELECT client_addr, state FROM pg_stat_replication;" 2>$null
```

### Phase 3: Create Base Backups for RO Replicas

```bash
# Backup1 is already done by docker-compose
# Now backup from Primary for RO nodes
cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro1
docker compose up -d
sleep 10
```

### Phase 4: Start All RO Replicas

```bash
# RO1
cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro1
docker compose up -d

# RO2
cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro2
docker compose up -d

# RO3
cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro3
docker compose up -d

sleep 15
```

### Phase 5: Start Monitoring Stack

```bash
cd c:\Users\reven\docker\postgres-ha-complete-v2\monitoring
docker compose up -d

sleep 10
```

**Access**:
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090

### Phase 6: Start Test Containers

```bash
cd c:\Users\reven\docker\postgres-ha-complete-v2\test-containers
docker compose up -d
```

**Containers**:
- `pg-writer`: Continuous writes to primary
- `pg-reader`: Continuous reads from all RO nodes
- `pg-validator`: Checks cluster sync status
- `pg-failover-sim`: Ready for failover testing

---

## Basic Operations

### Check Cluster Status

```bash
# View all nodes
docker ps | findstr "pg-"

# Full status with network info
docker network inspect ha-network
```

### Connect to Each Node

```bash
$env:PGPASSWORD = 'apppass'

# Primary (READ-WRITE)
psql -h localhost -p 5432 -U appuser -d appdb

# Backup1 (READ-ONLY)
psql -h localhost -p 5433 -U appuser -d appdb

# Backup2 (READ-ONLY)
psql -h localhost -p 5434 -U appuser -d appdb

# RO1 (READ-ONLY)
psql -h localhost -p 5440 -U appuser -d appdb

# RO2 (READ-ONLY)
psql -h localhost -p 5441 -U appuser -d appdb

# RO3 (READ-ONLY)
psql -h localhost -p 5442 -U appuser -d appdb
```

### View Replication Status

```bash
# On Primary - which servers are connected?
psql -h localhost -U appuser -d appdb -c "\
SELECT 
    application_name,
    client_addr,
    state,
    sync_state,
    write_lag
FROM pg_stat_replication;"

# Check replication slots
psql -h localhost -U appuser -d appdb -c "SELECT * FROM pg_replication_slots;"

# Check WAL position
psql -h localhost -U appuser -d appdb -c "SELECT pg_current_wal_lsn();"
```

---

## Synchronization Testing

### Test 1: Basic Sync Verification

```bash
# Step 1: Insert data into primary
psql -h localhost -U appuser -d appdb -c \
"INSERT INTO test_replication (message, node_id) 
 VALUES ('Test Message', 'primary');"

# Step 2: Wait 2 seconds for replication
Start-Sleep -Seconds 2

# Step 3: Query all nodes
for ($port in 5432, 5433, 5434, 5440, 5441, 5442) {
    $node = @{5432="Primary"; 5433="Backup1"; 5434="Backup2"; 5440="RO1"; 5441="RO2"; 5442="RO3"}[$port]
    $count = psql -h localhost -p $port -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_replication;" 2>$null
    Write-Host "$node (port $port): $count rows"
}
```

**Expected**: All nodes show same count

### Test 2: Bulk Data Sync

```bash
# Insert 1000 rows into primary
for ($i = 1; $i -le 1000; $i++) {
    psql -h localhost -U appuser -d appdb -c \
    "INSERT INTO sync_test (data) VALUES ('Test-$i-$(Get-Date -Format 'HHmmss.fff')') ON CONFLICT DO NOTHING;" 2>$null
    if ($i % 100 -eq 0) { Write-Host "Inserted $i rows..." }
}

# Check all nodes
Write-Host "`nVerifying sync across all nodes:"
for ($port in 5432, 5433, 5434, 5440, 5441, 5442) {
    $node = @{5432="Primary"; 5433="Backup1"; 5434="Backup2"; 5440="RO1"; 5441="RO2"; 5442="RO3"}[$port]
    $count = psql -h localhost -p $port -U appuser -d appdb -t -c "SELECT COUNT(*) FROM sync_test;" 2>$null
    Write-Host "  $node`: $count rows"
}
```

### Test 3: Real-time Writes During Reads

```bash
# Terminal 1: Start continuous writes
while ($true) {
    psql -h localhost -U appuser -d appdb -c \
    "INSERT INTO sync_test (data) VALUES ('Write-$(Get-Date -Millisecond)');" 2>$null
    Start-Sleep -Milliseconds 500
}

# Terminal 2: Start continuous reads from RO nodes
while ($true) {
    for ($port in 5440, 5441, 5442) {
        psql -h localhost -p $port -U appuser -d appdb -t -c "SELECT COUNT(*) FROM sync_test;" 2>$null &
    }
    Start-Sleep -Seconds 1
}

# Terminal 3: Monitor replication lag
while ($true) {
    psql -h localhost -U appuser -d appdb -c \
    "SELECT 
        application_name,
        NOW() - pg_last_xact_replay_timestamp() as replication_lag
     FROM pg_stat_replication;"
    Start-Sleep -Seconds 5
}
```

---

## Failover Testing

### Scenario 1: Graceful Primary Failover to Backup1

**Procedure**:

```bash
# Step 1: Monitor current state
Write-Host "Current Primary Status:"
psql -h localhost -p 5432 -U appuser -d appdb -c "SELECT pg_is_in_recovery();" 2>$null

# Step 2: Stop primary container
Write-Host "`nStopping primary..."
docker stop pg-primary

# Step 3: Promote backup1 to primary
Write-Host "Promoting backup1 to primary..."
docker exec pg-backup1 psql -U appuser -d appdb -c "SELECT pg_promote();" 2>$null

# Step 4: Wait for promotion
Start-Sleep -Seconds 10

# Step 5: Verify new primary
Write-Host "`nNew Primary Status:"
psql -h localhost -p 5433 -U appuser -d appdb -c "SELECT pg_is_in_recovery();" 2>$null

# Step 6: Test write on new primary
Write-Host "`nTesting write on new primary..."
psql -h localhost -p 5433 -U appuser -d appdb -c \
"INSERT INTO sync_test (data) VALUES ('Failover Test - New Primary');" 2>$null

# Step 7: Verify replication to remaining backup and RO nodes
Write-Host "`nVerifying other nodes can see new data:"
psql -h localhost -p 5434 -U appuser -d appdb -c \
"SELECT COUNT(*) FROM sync_test WHERE data LIKE 'Failover Test%';" 2>$null
```

### Scenario 2: Cascading Failover

```bash
# Step 1: Primary fails (already stopped)

# Step 2: Backup1 becomes primary (already promoted)

# Step 3: Rebuild old primary as new standby
Write-Host "Rebuilding old primary as standby..."
docker restart pg-primary

# Step 4: Wait for it to rejoin cluster
Start-Sleep -Seconds 15

# Step 5: Check all are connected to new primary (backup1)
psql -h localhost -p 5433 -U appuser -d appdb -c \
"SELECT client_addr, state FROM pg_stat_replication ORDER BY client_addr;"
```

### Scenario 3: Multiple Node Failure

```bash
# Simulate primary and backup1 both failing
docker stop pg-primary pg-backup1
Start-Sleep -Seconds 5

# Promote backup2 to primary
Write-Host "Promoting backup2 to primary..."
docker exec pg-backup2 psql -U appuser -d appdb -c "SELECT pg_promote();" 2>$null

# Rebuild old primary and backup1
docker start pg-primary
Start-Sleep -Seconds 10
docker start pg-backup1
Start-Sleep -Seconds 15

# Verify cluster state
Write-Host "`nCluster State After Recovery:"
for ($port in 5432, 5433, 5434) {
    $node = @{5432="pg-primary"; 5433="pg-backup1"; 5434="pg-backup2"}[$port]
    $is_primary = psql -h localhost -p $port -U appuser -d appdb -t -c \
    "SELECT CASE WHEN pg_is_in_recovery() THEN 'Standby' ELSE 'Primary' END;" 2>$null
    Write-Host "  $node (port $port): $is_primary"
}
```

---

## Monitoring

### Grafana Dashboard Access

1. Navigate to: http://localhost:3000
2. Login: admin / admin
3. Import PostgreSQL cluster dashboard

**Key Metrics to Monitor**:
- Replication lag across all nodes
- Connection count by node type
- Transaction rate (writes to primary)
- Read rate on RO nodes
- WAL archive status

### Prometheus Queries

```
# Active connections per node
postgres_numbackends{job="postgres_cluster"}

# Replication lag
rate(pg_stat_replication_lag[1m])

# Transaction rate
rate(pg_stat_user_commits[1m])

# Database size
postgres_database_size_bytes{datname="appdb"}

# Index statistics
postgres_stat_user_indexes_reads_total
```

### Manual Status Queries

```bash
# Connection summary
psql -h localhost -U appuser -d appdb -c \
"SELECT 
    usename,
    application_name,
    state,
    COUNT(*) as count
 FROM pg_stat_activity
 GROUP BY usename, application_name, state;"

# Table sizes
psql -h localhost -U appuser -d appdb -c \
"SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
 FROM pg_tables
 ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"

# Slow queries
psql -h localhost -U appuser -d appdb -c \
"CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
 SELECT 
    query,
    calls,
    mean_exec_time
 FROM pg_stat_statements
 ORDER BY mean_exec_time DESC LIMIT 10;"
```

---

## Troubleshooting

### Problem: Replication Lag Too High

**Diagnosis**:
```bash
psql -h localhost -U appuser -d appdb -c \
"SELECT 
    application_name,
    client_addr,
    NOW() - pg_last_xact_replay_timestamp() as lag
 FROM pg_stat_replication;"
```

**Solutions**:
```bash
# 1. Check network connectivity
docker exec pg-primary ping pg-backup1

# 2. Check WAL senders
psql -h localhost -U appuser -d appdb -c \
"SHOW max_wal_senders;"

# 3. Increase work_mem if needed
docker exec pg-primary psql -U appuser -d appdb -c \
"ALTER SYSTEM SET work_mem = '256MB'; SELECT pg_reload_conf();"
```

### Problem: Standby Not Accepting Writes

**Verification**:
```bash
# This should fail (read-only)
psql -h localhost -p 5433 -U appuser -d appdb -c \
"INSERT INTO sync_test (data) VALUES ('Test');" 2>&1

# Output should contain: "cannot execute INSERT"
```

**Solution**: Use `pg_promote()` if intentional promotion needed

### Problem: RO Node Out of Sync

**Recovery**:
```bash
# Stop the out-of-sync RO node
docker stop pg-ro1

# Remove its data volume
docker volume rm ro1_postgres_ro1_data

# Restart - it will auto-rebuild from primary
docker start pg-ro1

# Monitor logs
docker logs -f pg-ro1
```

---

## Automated Test Script

### Run Complete Test Suite

```powershell
# Full setup and validation
cd c:\Users\reven\docker\postgres-ha-complete-v2
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode all

# Run individual tests
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode test
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode validate
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode failover
```

### Test Output Example

```
╔════════════════════════════════════════════════════════════╗
║ Starting PostgreSQL HA Cluster                             ║
╚════════════════════════════════════════════════════════════╝
Starting Primary...
✓ Primary started
Starting Backup1...
✓ Backup1 started
...
✓ All nodes are healthy

╔════════════════════════════════════════════════════════════╗
║ Running Cluster Synchronization Test                       ║
╚════════════════════════════════════════════════════════════╝
Inserting test data into primary...
Verifying synchronization across all nodes:
  Primary: 100 rows
  Backup1: 100 rows
  Backup2: 100 rows
  RO1: 100 rows
  RO2: 100 rows
  RO3: 100 rows
✓ All nodes are in sync!
```

---

## Repeated Test Execution

### Create Test Schedule

Create file `test-schedule.ps1`:

```powershell
while ($true) {
    # Run complete test
    & "c:\Users\reven\docker\postgres-ha-complete-v2\cluster-manager.ps1" -Mode all
    
    # Wait 30 minutes
    Start-Sleep -Seconds 1800
    
    # Log timestamp
    Write-Host "Test cycle completed at $(Get-Date)" | Tee-Object -Append "test-log.txt"
}
```

Execute: `powershell -File test-schedule.ps1`

### Monitor Test Results

```bash
# Watch live logs
Get-Content test-log.txt -Wait

# Extract failures
Select-String "✗" test-log.txt

# Summary
Write-Host "Total tests run: $(Select-String '✓' test-log.txt | Measure-Object).Count"
Write-Host "Total failures: $(Select-String '✗' test-log.txt | Measure-Object).Count"
```

---

## Quick Reference: External Connection

### Always Connect to Current Primary

For external applications needing to always connect to the current primary:

```
Option 1: Use VIP (Requires Pacemaker)
- Single endpoint: postgresql://192.168.1.100:5432/appdb
- Pacemaker ensures VIP points to current primary

Option 2: Use HAProxy
- Endpoint: postgresql://localhost:5500/appdb
- HAProxy proxies to current primary

Option 3: Application-level failover
- Try ports 5432 → 5433 → 5434 until write succeeds
```

### Discover All RO Endpoints

```bash
# Query Consul/Etcd (if using service discovery)
curl http://localhost:8500/v1/catalog/service/postgresql-ro

# Or manually get all RO nodes
$RO_NODES = @(
    @{Name="ro1"; Port=5440}
    @{Name="ro2"; Port=5441}
    @{Name="ro3"; Port=5442}
)

# Connect to all for distributed reads
foreach ($node in $RO_NODES) {
    psql -h localhost -p $node.Port -U appuser -d appdb -c "SELECT COUNT(*) FROM sync_test;" &
}
```

---

## Summary of Files

```
postgres-ha-complete-v2/
├── ha-nodes/
│   ├── primary/
│   │   ├── docker-compose.yml
│   │   └── init-primary.sql
│   ├── backup1/
│   │   └── docker-compose.yml
│   └── backup2/
│       └── docker-compose.yml
├── ro-nodes/
│   ├── ro1/
│   ├── ro2/
│   └── ro3/
│   └── docker-compose.yml (x3)
├── monitoring/
│   ├── docker-compose.yml
│   └── prometheus.yml
├── test-containers/
│   └── docker-compose.yml
├── cluster-manager.ps1
└── TESTING_GUIDE.md (this file)
```

---

**Next Steps**:

1. Run: `powershell -File cluster-manager.ps1 -Mode setup`
2. Verify: `powershell -File cluster-manager.ps1 -Mode validate`
3. Test: `powershell -File cluster-manager.ps1 -Mode test`
4. Failover: `powershell -File cluster-manager.ps1 -Mode failover`

---
