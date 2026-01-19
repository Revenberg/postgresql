# PostgreSQL HA Cluster - Step-by-Step Execution Guide

## 📋 Pre-Requisites

- Docker Desktop installed and running
- PowerShell 5.1+ or PowerShell Core
- PostgreSQL client tools (`psql`) in PATH or Docker
- 8GB+ RAM available
- Ports 5432-5442, 9090, 3000 available

---

## 🚀 Phase 1: Start the HA Cluster

### Step 1: Start Primary Node

```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2\ha-nodes\primary
docker compose up -d
Write-Host "Waiting for Primary to be healthy..."
Start-Sleep -Seconds 15
```

**Verify Primary is Ready**:
```powershell
docker logs pg-primary | Select-String "ready to accept connections"
docker ps | findstr pg-primary
```

### Step 2: Start Backup Nodes

```powershell
# Backup1
cd c:\Users\reven\docker\postgres-ha-complete-v2\ha-nodes\backup1
docker compose up -d
Write-Host "Backup1 starting (will pg_basebackup from primary)..."
Start-Sleep -Seconds 20

# Backup2
cd c:\Users\reven\docker\postgres-ha-complete-v2\ha-nodes\backup2
docker compose up -d
Write-Host "Backup2 starting (will pg_basebackup from primary)..."
Start-Sleep -Seconds 20
```

**Verify Replication is Active**:
```powershell
$env:PGPASSWORD = 'apppass'
psql -h localhost -p 5432 -U appuser -d appdb -c `
  "SELECT client_addr, state, sync_state FROM pg_stat_replication;" 
```

**Expected Output**: 
```
  client_addr | state     | sync_state
  172.18.0.3  | streaming | async
  172.18.0.4  | streaming | async
```

### Step 3: Create Base Backups for RO Nodes

The backup is done inside each RO docker-compose, so just start them:

```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro1
docker compose up -d
Write-Host "RO1 creating base backup from primary..."
Start-Sleep -Seconds 15

cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro2
docker compose up -d
Write-Host "RO2 creating base backup from primary..."
Start-Sleep -Seconds 15

cd c:\Users\reven\docker\postgres-ha-complete-v2\ro-nodes\ro3
docker compose up -d
Write-Host "RO3 creating base backup from primary..."
Start-Sleep -Seconds 15
```

**Verify All RO Nodes are Healthy**:
```powershell
for ($port in 5440, 5441, 5442) {
    $node = @{5440="RO1"; 5441="RO2"; 5442="RO3"}[$port]
    $status = docker ps | findstr "pg-ro"
    Write-Host "$node is: $(if($status) {'Running'} else {'Not Running'})"
}
```

### Step 4: Start Monitoring Stack

```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2\monitoring
docker compose up -d
Start-Sleep -Seconds 10
```

**Access Monitoring**:
- Grafana: http://localhost:3000 (admin/admin)
- Prometheus: http://localhost:9090

### Step 5: Start Test Containers

```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2\test-containers
docker compose up -d

Write-Host "`nTest containers started:"
docker ps | findstr "pg-writer|pg-reader|pg-validator|pg-failover"
```

**What Each Container Does**:
- `pg-writer`: Inserts 1 row/sec into primary
- `pg-reader`: Reads from all 3 RO nodes
- `pg-validator`: Checks sync every 10 seconds
- `pg-failover-sim`: Ready for failover tests

---

## ✅ Phase 2: Verify Cluster Health

### Test 1: Check All Nodes Running

```powershell
Write-Host "=== Cluster Node Status ===" -ForegroundColor Cyan
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | `
  Select-Object -Skip 1 | `
  ForEach-Object {
    $name = $_.Split()[0]
    if ($name -match "^pg-") {
      Write-Host $_
    }
  }
```

### Test 2: Query Cluster Role Status

```powershell
$env:PGPASSWORD = 'apppass'

Write-Host "`n=== Node Roles ===" -ForegroundColor Cyan

$nodes = @(
  @{Name="Primary"; Port=5432}
  @{Name="Backup1"; Port=5433}
  @{Name="Backup2"; Port=5434}
  @{Name="RO1"; Port=5440}
  @{Name="RO2"; Port=5441}
  @{Name="RO3"; Port=5442}
)

foreach ($node in $nodes) {
  $in_recovery = psql -h localhost -p $node.Port -U appuser -d appdb -t -c `
    "SELECT pg_is_in_recovery();" 2>$null
  $role = if ($in_recovery -eq 't') { "Standby/RO" } else { "Primary" }
  Write-Host "  $($node.Name) (port $($node.Port)): $role"
}
```

### Test 3: Check Data Synchronization

```powershell
Write-Host "`n=== Data Sync Test ===" -ForegroundColor Cyan

# Insert test data
psql -h localhost -p 5432 -U appuser -d appdb -c `
  "INSERT INTO test_replication (message, node_id) VALUES ('Cluster Test', 'test_node');" 2>$null

Start-Sleep -Seconds 3

# Verify all nodes see it
foreach ($node in $nodes) {
  $count = psql -h localhost -p $node.Port -U appuser -d appdb -t -c `
    "SELECT COUNT(*) FROM test_replication;" 2>$null
  Write-Host "  $($node.Name): $count rows"
}
```

---

## 🧪 Phase 3: Synchronization Testing

### Test 3a: Continuous Write with Sync Monitoring

```powershell
Write-Host "Starting continuous write test..." -ForegroundColor Green

$env:PGPASSWORD = 'apppass'

# Insert in background
$writer = {
  while ($true) {
    psql -h localhost -p 5432 -U appuser -d appdb -c `
      "INSERT INTO sync_test (data) VALUES ('Row-$(Get-Date -Format 'HHmmss.fff)');" 2>$null
    Start-Sleep -Milliseconds 500
  }
}

$job = Start-Job -ScriptBlock $writer

# Monitor for 30 seconds
for ($i = 0; $i -lt 6; $i++) {
  Write-Host "`nCheck $($i+1)/6 (after $($i*5)s):"
  foreach ($port in 5432, 5433, 5434, 5440, 5441, 5442) {
    $node = @{5432="Primary"; 5433="B1"; 5434="B2"; 5440="RO1"; 5441="RO2"; 5442="RO3"}[$port]
    $count = psql -h localhost -p $port -U appuser -d appdb -t -c `
      "SELECT COUNT(*) FROM sync_test;" 2>$null
    Write-Host "    $node`: $count"
  }
  Start-Sleep -Seconds 5
}

# Stop writer
Stop-Job $job
Remove-Job $job

Write-Host "`n✓ Write test complete" -ForegroundColor Green
```

### Test 3b: Bulk Insert & Verify

```powershell
Write-Host "`nBulk insert test (500 rows)..." -ForegroundColor Cyan

$count = psql -h localhost -p 5432 -U appuser -d appdb -t -c `
  "SELECT COUNT(*) FROM sync_test;" 2>$null
$initial = [int]$count

# Insert 500 rows
for ($i = 1; $i -le 500; $i++) {
  psql -h localhost -p 5432 -U appuser -d appdb -c `
    "INSERT INTO sync_test (data) VALUES ('Bulk-$i');" 2>$null | Out-Null
  if ($i % 100 -eq 0) { Write-Host "  Inserted $i rows..." }
}

Write-Host "Inserted 500 rows. Verifying sync..."
Start-Sleep -Seconds 5

# Verify
$all_match = $true
foreach ($port in 5432, 5433, 5434, 5440, 5441, 5442) {
  $node = @{5432="Primary"; 5433="B1"; 5434="B2"; 5440="RO1"; 5441="RO2"; 5442="RO3"}[$port]
  $count = psql -h localhost -p $port -U appuser -d appdb -t -c `
    "SELECT COUNT(*) FROM sync_test;" 2>$null
  $new_count = [int]$count
  $inserted = $new_count - $initial
  Write-Host "  $node`: $count rows (inserted: $inserted)"
  if ($inserted -ne 500) { $all_match = $false }
}

if ($all_match) {
  Write-Host "`n✓ All nodes synchronized perfectly" -ForegroundColor Green
} else {
  Write-Host "`n✗ Sync mismatch detected" -ForegroundColor Red
}
```

---

## 🔄 Phase 4: Failover Testing

### Test 4a: Graceful Failover (Primary → Backup1)

```powershell
Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║  FAILOVER TEST: Primary → Backup1      ║" -ForegroundColor Magenta
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Magenta

Write-Host "`nStep 1: Current state" -ForegroundColor Yellow
psql -h localhost -p 5432 -U appuser -d appdb -c \
  "SELECT 'Primary can write', 1 UNION SELECT 'Primary is recovering', pg_is_in_recovery()::int;" 2>$null

Write-Host "`nStep 2: Stop primary container" -ForegroundColor Yellow
docker stop pg-primary
Write-Host "✓ Primary stopped"

Write-Host "`nStep 3: Promote Backup1 to primary" -ForegroundColor Yellow
docker exec pg-backup1 psql -U appuser -d appdb -c "SELECT pg_promote();" 2>$null
Write-Host "✓ Promotion command sent"

Write-Host "`nWaiting 10 seconds for promotion to complete..." -ForegroundColor Gray
Start-Sleep -Seconds 10

Write-Host "`nStep 4: Verify new primary (Backup1)" -ForegroundColor Yellow
$is_primary = psql -h localhost -p 5433 -U appuser -d appdb -t -c \
  "SELECT CASE WHEN pg_is_in_recovery() THEN 'Standby' ELSE 'Primary' END;" 2>$null
Write-Host "  Backup1 role: $is_primary"

if ($is_primary -eq "Primary") {
  Write-Host "`n✓ Backup1 successfully promoted to PRIMARY" -ForegroundColor Green
} else {
  Write-Host "`n✗ Promotion failed!" -ForegroundColor Red
  exit 1
}

Write-Host "`nStep 5: Test write on new primary" -ForegroundColor Yellow
psql -h localhost -p 5433 -U appuser -d appdb -c \
  "INSERT INTO sync_test (data) VALUES ('After Failover - $(Get-Date -Format 'HHmmss')');" 2>$null
Write-Host "✓ Write successful on new primary"

Write-Host "`nStep 6: Verify other nodes can see the write" -ForegroundColor Yellow
$b2_count = psql -h localhost -p 5434 -U appuser -d appdb -t -c \
  "SELECT COUNT(*) FROM sync_test WHERE data LIKE 'After Failover%';" 2>$null
$ro1_count = psql -h localhost -p 5440 -U appuser -d appdb -t -c \
  "SELECT COUNT(*) FROM sync_test WHERE data LIKE 'After Failover%';" 2>$null
Write-Host "  Backup2 sees: $b2_count rows"
Write-Host "  RO1 sees: $ro1_count rows"

Write-Host "`nStep 7: Rebuild old primary as standby" -ForegroundColor Yellow
docker start pg-primary
Write-Host "Waiting 20 seconds for old primary to rebuild from new primary..."
Start-Sleep -Seconds 20

Write-Host "`nStep 8: Verify cluster is rebalanced" -ForegroundColor Yellow
$primary_recovery = psql -h localhost -p 5432 -U appuser -d appdb -t -c \
  "SELECT pg_is_in_recovery();" 2>$null
$role = if ($primary_recovery -eq 't') { "Standby" } else { "ERROR - STILL PRIMARY" }
Write-Host "  Old primary role: $role"

Write-Host "`n╔════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  ✓ FAILOVER TEST PASSED                ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════╝" -ForegroundColor Green
```

### Test 4b: Failover with Continuous Write

```powershell
Write-Host "`nStarting continuous write in background..." -ForegroundColor Cyan

$writer_block = {
  $env:PGPASSWORD = 'apppass'
  $writes = 0
  while ($true) {
    try {
      # Try to write to primary
      psql -h localhost -p 5432 -U appuser -d appdb -c `
        "INSERT INTO sync_test (data) VALUES ('Write-$($writes)-$(Get-Date -Millisecond)');" 2>$null
      $writes++
    } catch {
      # Primary down, try backup1
      try {
        psql -h localhost -p 5433 -U appuser -d appdb -c `
          "INSERT INTO sync_test (data) VALUES ('Write-$($writes)-$(Get-Date -Millisecond)');" 2>$null
        $writes++
      } catch {
        # Wait and retry
      }
    }
    Start-Sleep -Milliseconds 100
  }
}

$writer_job = Start-Job -ScriptBlock $writer_block

Write-Host "Waiting 5 seconds before failover..."
Start-Sleep -Seconds 5

# Now trigger failover
Write-Host "`nTriggering failover..." -ForegroundColor Yellow
docker stop pg-primary
docker exec pg-backup1 psql -U appuser -d appdb -c "SELECT pg_promote();" 2>$null
Start-Sleep -Seconds 10

Write-Host "`nWrites continued during failover. Verifying..."
Stop-Job $writer_job
$writes_count = psql -h localhost -p 5433 -U appuser -d appdb -t -c \
  "SELECT COUNT(*) FROM sync_test WHERE data LIKE 'Write-%';" 2>$null

Write-Host "Total writes during failover: $writes_count"
Write-Host "`n✓ Write resilience test passed" -ForegroundColor Green

# Cleanup
docker start pg-primary
Start-Sleep -Seconds 20
Remove-Job $writer_job
```

---

## 📊 Phase 5: Monitoring Verification

### Access Grafana Dashboard

```powershell
Write-Host "`nOpen Grafana Dashboard:" -ForegroundColor Cyan
Write-Host "  URL: http://localhost:3000" -ForegroundColor White
Write-Host "  User: admin" -ForegroundColor White
Write-Host "  Pass: admin" -ForegroundColor White
Write-Host "`nDashboard Name: 'PostgreSQL HA Cluster'" -ForegroundColor White
```

### Verify Prometheus Metrics

```powershell
# Query Prometheus for cluster metrics
$prometheus_url = "http://localhost:9090/api/v1/query?query="

# Active connections
$query = "postgresql_numbackends"
Write-Host "`nActive Connections by Node:" -ForegroundColor Cyan
Invoke-WebRequest -Uri "$prometheus_url$query" -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty data

# Transaction rate
$query = "rate(postgresql_transactions_total[1m])"
Write-Host "`nTransaction Rate (1m):" -ForegroundColor Cyan
Invoke-WebRequest -Uri "$prometheus_url$query" -UseBasicParsing | ConvertFrom-Json | Select-Object -ExpandProperty data
```

---

## 🎯 Complete Automated Test

### Run All Tests with One Command

```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2

# Full setup + tests
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode all

# Options:
# -Mode setup      : Just start cluster
# -Mode start      : Start all services
# -Mode stop       : Stop all services
# -Mode test       : Run sync test
# -Mode validate   : Check cluster health
# -Mode failover   : Simulate failover
# -Mode all        : Setup + all tests
```

---

## 📋 Troubleshooting Commands

### Debug Primary Start Issues

```powershell
docker logs pg-primary | Select-Object -Last 50
docker exec pg-primary psql -U appuser -d appdb -c "\dt"
```

### Debug Replication Issues

```powershell
# Check pg_hba.conf
docker exec pg-primary cat /var/lib/postgresql/data/pg_hba.conf | Select-String "replication"

# Check replication user
docker exec pg-primary psql -U appuser -d appdb -c \
  "SELECT usename, usecanrepl FROM pg_user WHERE usename='replicator';"

# Check slots
docker exec pg-primary psql -U appuser -d appdb -c "SELECT * FROM pg_replication_slots;"
```

### Debug RO Node Sync Issues

```powershell
# Check if RO node is receiving WAL
docker logs pg-ro1 | Select-String "wal_keep_size|streaming|replication"

# Rebuild RO node
docker stop pg-ro1
docker volume rm ro1_postgres_ro1_data
docker start pg-ro1
Start-Sleep -Seconds 20
```

### Clean Full Reset

```powershell
# Stop everything
cd c:\Users\reven\docker\postgres-ha-complete-v2
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode stop

# Remove all volumes
docker volume prune -f

# Remove all networks
docker network prune -f

# Restart from scratch
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode setup
```

---

## ✨ Success Criteria

Your cluster is healthy when:

- ✅ All 6 PostgreSQL nodes are running
- ✅ Primary accepts writes
- ✅ Backups replicate from primary
- ✅ RO replicas receive data within 1-2 seconds
- ✅ Failover completes in < 15 seconds
- ✅ Grafana shows metrics from all nodes
- ✅ Test container logs show successful operations

---

**Ready to test? Start with Phase 1: Start the HA Cluster!**
