# PostgreSQL High Availability Setup with Prometheus Monitoring

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                   PostgreSQL HA Cluster with Monitoring                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                           │
│  ┌──────────────────┐                                                   │
│  │ postgres-primary │  (Master - Read/Write)                            │
│  │   Port: 5432     │  WAL Replication ──→ Replicas                     │
│  │  Accepts Writes  │                                                   │
│  └──────┬───────────┘                                                   │
│         │                                                                │
│    ┌────┴──────────────────────┐                                        │
│    ▼                           ▼                                        │
│  ┌──────────────────┐    ┌──────────────────┐                         │
│  │postgres-replica-1│    │postgres-replica-2│  (Standbys - Read-Only) │
│  │   Port: 5433     │    │   Port: 5434     │  Real-time Sync         │
│  │   Read-only      │    │   Read-only      │                         │
│  └────────┬─────────┘    └────────┬─────────┘                         │
│           │                       │                                    │
│    ┌──────┴───────────────────────┴──────┐                             │
│    ▼                                     ▼                             │
│  ┌───────────────────┐           ┌──────────────────┐                 │
│  │   webserver       │           │  prometheus-srv  │                 │
│  │  Flask UI         │           │  Metrics & Stats │                 │
│  │ Port: 5000        │           │   Port: 9090     │                 │
│  │                   │           │                  │                 │
│  │ Shows:            │           │ Exporters:       │                 │
│  │ - Row Counts      │           │ - Primary (9187) │                 │
│  │ - Replication     │           │ - Replica-1 (9188)                │
│  │ - Server Info     │           │ - Replica-2 (9189)                │
│  └───────────────────┘           └──────────────────┘                 │
│                                                                           │
└─────────────────────────────────────────────────────────────────────────┘
```

## Components

### PostgreSQL Servers
| Service | Port | Role | Purpose |
|---------|------|------|---------|
| `postgres-primary` | 5432 | Primary | Master - accepts reads & writes |
| `postgres-replica-1` | 5433 | Standby | Read-only replica with real-time sync |
| `postgres-replica-2` | 5434 | Standby | Read-only replica with real-time sync |

### Monitoring & Web UI
| Service | Port | Purpose |
|---------|------|---------|
| `webserver` | 5000 | Flask dashboard - view row counts, replication status |
| `prometheus` | 9090 | Prometheus server - metrics collection & graphs |
| `postgres-exporter-primary` | 9187 | Prometheus exporter for primary |
| `postgres-exporter-replica-1` | 9188 | Prometheus exporter for replica-1 |
| `postgres-exporter-replica-2` | 9189 | Prometheus exporter for replica-2 |

## How It Works

### Primary (Master) - postgres-primary:5432
- Accepts read and write operations
- Generates WAL (Write-Ahead Log) records
- Streams replication data to both standby servers
- Contains the authoritative copy of data

### Replicas (Standbys) - postgres-replica-1/2:5433-5434
- Read-only copies of primary database
- Receive WAL stream from primary in real-time
- Can be promoted to primary if primary fails (manual failover)
- Used for load balancing read queries
- Monitor via Prometheus exporters

### Monitoring Stack
- **Prometheus**: Scrapes metrics from PostgreSQL exporters every 15 seconds
- **Exporters**: Convert PostgreSQL metrics to Prometheus format
- **Webserver**: Flask UI shows row counts and replication status

## Getting Started

### Prerequisites
- Docker & Docker Compose installed
- Ports available: 5432-5434 (PostgreSQL), 5000 (Flask), 9090-9189 (Prometheus)

### Start the HA Cluster

```powershell
cd c:\Users\reven\docker\postgreSQL

# Clean up any existing containers and volumes
docker-compose down -v

# Build and start all services (Primary, 2 Replicas, Webserver, Prometheus)
docker-compose up -d

# Watch the logs
docker-compose logs -f
```

### Verify All Services Are Running

```powershell
# Check all containers
docker-compose ps

# All should show "Up" status and healthy
```

### Access the Services

1. **Flask Dashboard** (View row counts & replication status)
   - URL: http://localhost:5000
   - Shows: Primary server info, replica status, replication progress, row counts

2. **Prometheus Metrics UI** (View Prometheus targets & query metrics)
   - URL: http://localhost:9090
   - Targets: http://localhost:9090/targets (all should show "UP")
   - Graph: http://localhost:9090/graph

### Verify Replication Status

**Check Primary Replication Status:**
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "SELECT client_addr, usename, state, sync_state, write_lag, replay_lag FROM pg_stat_replication;"
```

**Check Replica-1 Status:**
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-replica-1 psql -U testadmin -d testdb -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn();"
```

**Check Replica-2 Status:**
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-replica-2 psql -U testadmin -d testdb -c \
  "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn();"
```

**Expected Output:**
- `pg_is_in_recovery()` = `t` (true) - indicates standby mode
- Replicas should appear in primary's `pg_stat_replication`

## Connection Strings

### Write Operations (Connect to Primary Only)
```
Host: postgres-primary (or localhost:5432)
User: testadmin
Password: securepwd123
Database: testdb

# Connection String
postgres://testadmin:securepwd123@postgres-primary:5432/testdb
postgres://testadmin:securepwd123@localhost:5432/testdb
```

### Read Operations (Can Use Primary or Either Replica)

**Primary (Read & Write)**
```
postgres://testadmin:securepwd123@postgres-primary:5432/testdb
postgres://testadmin:securepwd123@localhost:5432/testdb
```

**Replica-1 (Read-Only)**
```
postgres://testadmin:securepwd123@postgres-replica-1:5432/testdb
postgres://testadmin:securepwd123@localhost:5433/testdb
```

**Replica-2 (Read-Only)**
```
postgres://testadmin:securepwd123@postgres-replica-2:5432/testdb
postgres://testadmin:securepwd123@localhost:5434/testdb
```

### Database Details
| Property | Value |
|----------|-------|
| Database | testdb |
| Username | testadmin |
| Password | securepwd123 |
| Tables | users, nodes, messages |

## Testing Failover

### 1. Simulate Primary Failure
```powershell
docker-compose stop postgres-primary
```

### 2. Verify Replicas Detect Failure
```powershell
docker-compose logs postgres-replica-1
docker-compose logs postgres-replica-2
# Look for: "waiting for WAL to become available"
```

### 3. Promote Replica-1 to Primary (Manual Failover)
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-replica-1 psql -U testadmin -d testdb -c \
  "SELECT pg_promote();"
```

### 4. Verify Promotion
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-replica-1 psql -U testadmin -d testdb -c \
  "SELECT pg_is_in_recovery();"
```
**Expected Output:** `f` (false) - Replica-1 is now a primary

### 5. Restart Original Primary
```powershell
docker-compose start postgres-primary
```

### 6. Reconfigure Original Primary as New Replica
```powershell
# Remove old replica data
docker volume rm postgresql-postgres_primary_data

# Restart to clone from new primary (replica-1)
docker-compose up -d postgres-primary
```

## Monitoring with Prometheus

### View Prometheus Targets
```
http://localhost:9090/targets
```
All targets should show "UP":
- `postgres-primary` (9187)
- `postgres-replica-1` (9188)
- `postgres-replica-2` (9189)

### Useful Prometheus Queries

**Replication Lag (Bytes):**
```promql
pg_replication_lag_bytes
```

**Active Connections:**
```promql
pg_stat_activity_count
```

**Transactions Per Second:**
```promql
rate(pg_stat_database_xact_commit[1m]) + rate(pg_stat_database_xact_rollback[1m])
```

**Cache Hit Ratio:**
```promql
rate(pg_stat_database_heap_blks_hit[5m]) / (rate(pg_stat_database_heap_blks_hit[5m]) + rate(pg_stat_database_heap_blks_read[5m]))
```

**Database Size:**
```promql
pg_database_size_bytes
```

**Rows in Tables:**
```promql
pg_stat_user_tables_n_live_tup
```

### Viewing Metrics in Flask Dashboard
```
http://localhost:5000

Shows:
- Primary server role, version, current time
- Row counts for all tables (Primary & Replicas)
- Replica connection status
- Replication progress bar with WAL lag
- Replication statistics table
```

## Production Considerations

1. **Synchronous Replication**: Enable `synchronous_commit` for data safety
2. **Connection Pooling**: Use pgBouncer for connection pooling
3. **Monitoring**: Prometheus + Grafana dashboard (currently using Prometheus)
4. **Backup**: Configure `archive_command` for WAL archiving
5. **Encryption**: Enable SSL/TLS for all connections
6. **Network**: Use dedicated replication network (done via Docker bridge)
7. **Storage**: Use persistent volumes on production servers (implemented)
8. **Automatic Failover**: Consider Patroni or etcd for leader election
9. **High Availability**: Add VIP (Virtual IP) using keepalived for transparent failover
10. **Load Balancing**: Use HAProxy or pgpool-II for read query load balancing

## Troubleshooting

### Replica Won't Connect to Primary
```powershell
# Check replica logs
docker-compose logs postgres-replica-1

# Verify primary is accepting replication connections
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "SELECT * FROM pg_stat_replication;"

# Common issue: pg_hba.conf doesn't have replication entry
# Should be added automatically by docker-entrypoint-primary.sh
```

### Replication Lag High
```powershell
# Slow network or high write load
# Check lag:
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "SELECT client_addr, replay_lag FROM pg_stat_replication;"

# Solutions:
# 1. Increase wal_keep_size
# 2. Increase max_wal_senders
# 3. Check network bandwidth
```

### Connection Refused
```powershell
# Ensure all services are running
docker-compose ps

# Check network connectivity
docker exec postgres-primary ping postgres-replica-1
docker exec postgres-primary ping postgres-replica-2

# Check if ports are listening
docker port postgres-primary
docker port postgres-replica-1
docker port postgres-replica-2
```

### Prometheus Not Scraping Metrics
```powershell
# Check Prometheus logs
docker-compose logs prometheus

# Verify exporters are running
docker-compose ps | grep exporter

# Test exporter directly
curl http://localhost:9187/metrics
curl http://localhost:9188/metrics
curl http://localhost:9189/metrics
```

### Flask Dashboard Shows "NULL" Values
```powershell
# Check if replicas can be queried
curl http://localhost:5000

# Check Flask logs
docker-compose logs webserver

# Replicas might still be in recovery mode
# This is normal - data will sync as it arrives
```

## Maintenance Tasks

### Restart All Services
```powershell
docker-compose restart
```

### View Real-Time Logs
```powershell
docker-compose logs -f
docker-compose logs -f postgres-primary
docker-compose logs -f postgres-replica-1
docker-compose logs -f postgres-replica-2
docker-compose logs -f webserver
docker-compose logs -f prometheus
```

### Check Database Size
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database WHERE datname='testdb';"
```

### List All Tables and Row Counts
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;"
```

### Manual Backup
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-primary pg_dump -U testadmin testdb > backup_$(date +%Y%m%d_%H%M%S).sql
```

## Performance Tuning

### Monitor Query Performance
```powershell
# Enable query logging in postgres-primary
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "ALTER SYSTEM SET log_min_duration_statement = 1000; SELECT pg_reload_conf();"
```

### Check Index Usage
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "SELECT schemaname, tablename, indexname, idx_scan FROM pg_stat_user_indexes ORDER BY idx_scan ASC;"
```

### Analyze Query Plans
```powershell
docker exec -e PGPASSWORD=securepwd123 postgres-primary psql -U testadmin -d testdb -c \
  "EXPLAIN ANALYZE SELECT * FROM users LIMIT 10;"
```
