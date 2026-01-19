# PostgreSQL HA Cluster - Node Renaming & 30-Min Test Setup ✅

## 1. Container Renaming Completed

### Before (Role-Based Names)
```
pg-primary   (port 5432)
pg-backup1   (port 5433)  
pg-backup2   (port 5434)
pg-ro1       (port 5440)
pg-ro2       (port 5441)
pg-ro3       (port 5442)
```

### After (Neutral Node Numbering) ✅
```
pg-node-1    (port 5432) - Primary write node
pg-node-2    (port 5433) - Standby/Replica 
pg-node-3    (port 5434) - Standby/Replica
pg-node-4    (port 5440) - Read-only replica
pg-node-5    (port 5441) - Read-only replica
pg-node-6    (port 5442) - Read-only replica
```

### Benefits of Neutral Naming
- Roles can change dynamically (promotes, demotions, failover)
- Names don't imply function - enables flexible architecture
- Easier to reason about node numbering
- Compatible with automated failover systems

---

## 2. Files Modified for Renaming

### docker-compose.yml
- Renamed all service names: `pg-primary` → `pg-node-1`, etc.
- Updated volume names: `postgres_primary_data` → `postgres_node1_data`, etc.
- Updated labels: `pg-cluster=primary` → `pg-cluster=node`
- Updated dependencies: `depends_on: pg-primary` → `depends_on: pg-node-1`

### entrypoint-backup.sh
- Updated primary reference: `pg-primary` → `pg-node-1` (2 occurrences in pg_basebackup command)

### entrypoint-ro.sh
- Updated primary reference: `pg-primary` → `pg-node-1` (2 occurrences in pg_basebackup command)

### monitoring/docker-compose.yml
- Renamed exporters: `exporter-primary` → `exporter-node-1`, etc.
- Updated DATA_SOURCE_NAME connections for all 6 exporters
- Each exporter on unique port (9187-9192)

### monitoring/prometheus.yml
- Updated all scrape jobs to use new exporter names
- Simplified labels (removed role/redundant info)

---

## 3. 30-Minute Test Scripts Created

### Option A: PowerShell (Windows) ✅
**File**: `test-30min.ps1`

**Usage**:
```powershell
# Run 30-minute test without auto-restart
.\test-30min.ps1

# Run with auto-restart after 30 minutes
.\test-30min.ps1 -AutoRestart:$true

# Custom duration (in seconds)
.\test-30min.ps1 -Duration 3600 -AutoRestart:$true
```

**Features**:
- Configurable test duration (default: 1800 seconds = 30 minutes)
- Continuous write workload (rows to primary)
- Concurrent read workload (from all 6 nodes)
- Real-time data sync validation
- Auto-restart option (graceful stop/start all containers)
- Detailed logging to `test-logs/` directory
- Metrics tracking (rows written, sync lag detection)
- Color-coded console output
- Clean signal handling (Ctrl+C graceful shutdown)

**Output Artifacts**:
- `test-logs/test-YYYYMMDD-HHMMSS.log` - Full execution log
- `test-logs/metrics-YYYYMMDD-HHMMSS.log` - Metrics and sync validation
- `test-logs/restart.log` - Auto-restart events (if enabled)

### Option B: Bash (Linux/WSL) ✅
**File**: `test-30min.sh`

**Usage**:
```bash
# Run without restart
bash test-30min.sh

# Run with auto-restart
bash test-30min.sh restart

# Make executable and run
chmod +x test-30min.sh
./test-30min.sh restart
```

**Features**:
- Same functionality as PowerShell version
- Uses Docker exec directly
- Colored output  
- Parallel background jobs for write/read/validate
- Clean logging structure

---

## 4. Test Workload Details

### Write Workload
- Inserts 10 rows per second to primary (pg-node-1)
- Stores in `test_data` table
- Tracks batch count for progress monitoring

### Read Workload
- Concurrent queries to all 6 nodes
- Reads every 2 seconds
- Verifies all nodes are accessible

### Validation Workload  
- Checks row counts every 10 seconds
- Compares primary row count vs. all replicas
- Detects replication lag
- Logs sync status to metrics file

### Auto-Restart (Optional)
- Runs test for exactly 30 minutes
- Then gracefully stops all containers
- Waits 10 seconds
- Restarts all containers
- Verifies all 6 nodes come back healthy
- Logs restart events

---

## 5. Test Output Example

```
================================
PostgreSQL HA Cluster - 30 Minute Test
================================
ℹ Test Configuration:
ℹ  Duration: 1800 seconds (30 minutes)
ℹ  Auto-Restart: True
ℹ  Log File: test-logs/test-20260118-180000.log
ℹ  Metrics File: test-logs/metrics-20260118-180000.log

ℹ Initializing test table...
✓ Test table created
ℹ Starting workloads...
✓ All workloads started

ℹ Test running for 30 minutes...
Elapsed: 1245s | Remaining: 15m 45s | Nodes: 6/6
Elapsed: 1250s | Remaining: 15m 40s | Nodes: 6/6
...

[After 30 minutes]

ℹ Auto-Restart enabled - restarting cluster
ℹ Stopping all containers...
ℹ Restarting containers...
✓ Cluster restarted and healthy (6/6 nodes)

================================
Test Summary
================================
✓ Test completed successfully
ℹ Final row count: 18000
ℹ Log: test-logs/test-20260118-180000.log
ℹ Metrics: test-logs/metrics-20260118-180000.log
```

---

## 6. Metrics File Contents

```
18:00:00 - Write batches: 10 | Total rows: 100
18:00:30 - Write batches: 30 | Total rows: 300
18:00:45 - ✓ All nodes synced: 300 rows
18:01:00 - Write batches: 60 | Total rows: 600
18:01:30 - ✓ All nodes synced: 600 rows
18:02:00 - ⚠ Sync lag on pg-node-3: primary=700 vs pg-node-3=650
18:02:10 - ✓ All nodes synced: 700 rows
...
```

---

## 7. How to Use

### Step 1: Start the Cluster
```powershell
cd c:\Users\reven\docker\postgres-ha-complete-v2
docker compose up -d
```

### Step 2: Wait for Nodes to Be Ready
```powershell
# Wait ~2-3 minutes for all nodes to synchronize

# Check status
docker compose ps

# Should show all 7 containers (6 PG nodes + etcd)
# All PostgreSQL nodes should be "healthy"
```

### Step 3: Start Monitoring (Optional)
```powershell
cd monitoring
docker compose up -d

# Grafana: http://localhost:3000 (admin/admin)
# Prometheus: http://localhost:9090
```

### Step 4: Run 30-Minute Test
```powershell
# Without auto-restart
.\test-30min.ps1

# With auto-restart
.\test-30min.ps1 -AutoRestart:$true

# Custom duration (60 minutes with restart)
.\test-30min.ps1 -Duration 3600 -AutoRestart:$true

# View logs in real-time
Get-Content test-logs/test-*.log -Wait

# View metrics
Get-Content test-logs/metrics-*.log -Wait
```

### Step 5: Verify Replication
```powershell
# Check row counts across all nodes
for ($i = 1; $i -le 6; $i++) {
    $count = docker exec "pg-node-$i" psql -U appuser -d appdb -t -c "SELECT COUNT(*) FROM test_data;"
    Write-Host "Node-$i: $count rows"
}
```

---

## 8. Architecture Diagram

```
┌──────────────────────── PostgreSQL HA Cluster ──────────────────────┐
│                                                                       │
│  ┌─────────────┐                                                    │
│  │ pg-node-1   │ (Primary, Port 5432)                              │
│  │ ✓ healthy   │ ← Receives all writes                             │
│  └─────────────┘                                                    │
│         │                                                            │
│         ├─ Streaming Replication (Slots)                           │
│         │                                                            │
│  ┌──────┴──────┬──────────┐                                         │
│  │             │          │                                         │
│  ▼             ▼          ▼                                         │
│┌───────────┐ ┌───────────┐ ┌───────────┐                          │
││pg-node-2  │ │pg-node-3  │ │pg-node-4  │ (Read-only Replicas)    │
││Port 5433  │ │Port 5434  │ │Port 5440  │                          │
││Standby    │ │Standby    │ │RO Replica │                          │
│└───────────┘ └───────────┘ └───────────┘                          │
│  │             │          │                                         │
│  └──────┬──────┴──────────┘                                         │
│  ┌──────┴──────┐                                                    │
│  ▼             ▼                                                    │
│┌───────────┐ ┌───────────┐                                         │
││pg-node-5  │ │pg-node-6  │ (Read-only Replicas)                   │
││Port 5441  │ │Port 5442  │                                         │
││RO Replica │ │RO Replica │                                         │
│└───────────┘ └───────────┘                                         │
│                                                                      │
│  All Nodes Connected:                                              │
│  - Network: postgres-ha-complete-v2_ha-network (Bridge)          │
│  - Service Discovery: etcd-primary (port 2379)                    │
│  - Replication Method: pg_basebackup + streaming                  │
│  - Replication Slots: 5 physical slots (1 per replica)            │
│                                                                      │
└──────────────────────────────────────────────────────────────────┘

┌──────────────────────── Monitoring Stack ──────────────────────────┐
│                                                                     │
│  Prometheus (port 9090)                                           │
│  ├─ exporter-node-1 (port 9187)                                   │
│  ├─ exporter-node-2 (port 9188)                                   │
│  ├─ exporter-node-3 (port 9189)                                   │
│  ├─ exporter-node-4 (port 9190)                                   │
│  ├─ exporter-node-5 (port 9191)                                   │
│  └─ exporter-node-6 (port 9192)                                   │
│                                                                     │
│  Grafana (port 3000)                                              │
│  └─ PostgreSQL HA Cluster Dashboard                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 9. Troubleshooting

### Nodes Unhealthy?
```powershell
# Check node logs
docker logs pg-node-1
docker logs pg-node-2

# Check network connectivity
docker network ls
docker network inspect postgres-ha-complete-v2_ha-network

# Restart problematic node
docker restart pg-node-2
```

### Test Won't Start?
```powershell
# Ensure test table exists
docker exec pg-node-1 psql -U appuser -d appdb -c "SELECT COUNT(*) FROM test_data;"

# If table missing, create manually
docker exec pg-node-1 psql -U appuser -d appdb -c "
CREATE TABLE IF NOT EXISTS test_data (
    id SERIAL PRIMARY KEY,
    test_value VARCHAR(255),
    created_at TIMESTAMP
);"
```

### Replication Lagging?
```powershell
# Check replication slots
docker exec pg-node-1 psql -U appuser -d appdb -c "SELECT * FROM pg_replication_slots;"

# Check active replicas
docker exec pg-node-1 psql -U appuser -d appdb -c "SELECT * FROM pg_stat_replication;"
```

---

## 10. Next Steps

1. ✅ Verify all 6 nodes become healthy
2. ⏳ Run 30-minute test without auto-restart
3. ⏳ Run 30-minute test WITH auto-restart
4. ⏳ Verify Grafana dashboards show metrics
5. ⏳ Test failover scenarios
6. ⏳ Run long-term stability tests

---

**Status**: ✅ RENAMING COMPLETE & TEST SCRIPTS READY

**Node Naming**: pg-node-1 through pg-node-6 (neutral, role-agnostic)
**Test Duration**: 30 minutes (configurable)
**Auto-Restart**: Optional (graceful cluster restart after test)
**Logging**: Comprehensive (test + metrics + restart logs)

Last Updated: 2026-01-18 18:XX UTC
