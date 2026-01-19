# PostgreSQL HA Cluster v2.0

Advanced High-Availability PostgreSQL Cluster with:
- **1 Primary** (read-write)
- **2 Backup/Standby nodes** (async replication, read-only)
- **3 RO Replicas** (dedicated read-only replicas)
- **Monitoring** (Prometheus + Grafana)
- **Automated Testing** (Write/Read/Failover tests)

---

## 📋 Quick Start

### 1. Full Cluster Setup

```bash
cd c:\Users\reven\docker\postgres-ha-complete-v2
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode setup
```

### 2. Check Status

```bash
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode validate
```

### 3. Run Tests

```bash
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode test
```

### 4. Simulate Failover

```bash
powershell -ExecutionPolicy Bypass -File cluster-manager.ps1 -Mode failover
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  CLIENT APPLICATIONS                    │
└────┬────────────────────┬────────────────────┬──────────┘
     │                    │                    │
  (Write)            (Read)               (Read)
     │                    │                    │
     ▼                    ▼                    ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────────┐
│   PRIMARY    │  │   BACKUP-1   │  │   BACKUP-2 / RO  │
│  (5432)      │◄─►(5433)       │  │   (5434)         │
│ Read-Write   │  │ Read-Only    │  │   Read-Only      │
└──────────────┘  └──────────────┘  └──────────────────┘
     ▲                   ▲                    ▲
     └───────────────────┴────────────────────┘
       Streaming Replication via WAL

     ┌─────────────────────────────────────┐
     │  3 RO Replicas (5440, 5441, 5442)   │
     │  - pg-ro1 (Port 5440)               │
     │  - pg-ro2 (Port 5441)               │
     │  - pg-ro3 (Port 5442)               │
     └─────────────────────────────────────┘

┌─────────────────────────────────────────────┐
│  Monitoring Stack                           │
│  - Prometheus (9090)                        │
│  - Grafana (3000) - admin/admin            │
│  - PostgreSQL Exporter (9187)              │
└─────────────────────────────────────────────┘
```

---

## 🎯 Key Features

### High Availability
- **Automatic Failover**: Backup nodes can be promoted if primary fails
- **Cascading Replication**: Changes flow from Primary → Backups → RO Replicas
- **Zero Data Loss**: Synchronous commit option available
- **Point-in-Time Recovery**: WAL archiving support

### Scalability
- **Multiple Readers**: 3 dedicated RO replicas for distributed reads
- **Load Distribution**: Reads balanced across RO nodes
- **Backup Strategy**: Full + incremental backup support

### Monitoring & Alerting
- **Real-time Metrics**: Prometheus + Grafana dashboards
- **Replication Monitoring**: Lag tracking across all nodes
- **Connection Pooling**: Connection state visibility

### Testing & Validation
- **Automated Tests**: Write/Read/Failover scenarios
- **Sync Verification**: Cross-node consistency checks
- **Performance Profiling**: Query and transaction metrics

---

## 📊 Component Breakdown

### HA Nodes (Cluster Election)

| Node | Port | Role | Replicate From | Replicate To |
|------|------|------|----------------|-------------|
| Primary | 5432 | Write | - | Backup1, Backup2, RO* |
| Backup1 | 5433 | Standby | Primary | RO* |
| Backup2 | 5434 | Standby | Primary | RO* |

### RO Replicas (Read-Only Scale)

| Node | Port | Role | Replicate From |
|------|------|------|----------------|
| RO1 | 5440 | Read-Only | Primary |
| RO2 | 5441 | Read-Only | Primary |
| RO3 | 5442 | Read-Only | Primary |

### Monitoring

| Service | Port | URL |
|---------|------|-----|
| Prometheus | 9090 | http://localhost:9090 |
| Grafana | 3000 | http://localhost:3000 |
| Exporter | 9187 | http://localhost:9187/metrics |

---

## 🚀 Operations

### Connect to Nodes

```bash
$env:PGPASSWORD = 'apppass'

# Primary (Write)
psql -h localhost -p 5432 -U appuser -d appdb

# Backup1/2 (Read-Only)
psql -h localhost -p 5433 -U appuser -d appdb

# RO Replicas (Read-Only)
psql -h localhost -p 5440 -U appuser -d appdb
```

### Check Replication Status

```bash
psql -h localhost -U appuser -d appdb -c "SELECT * FROM pg_stat_replication;"
```

### Monitor Cluster Health

```bash
# Container status
docker ps | findstr pg-

# Network connectivity
docker network inspect ha-network

# Replication lag
psql -h localhost -U appuser -d appdb -c \
"SELECT application_name, NOW() - pg_last_xact_replay_timestamp() as lag FROM pg_stat_replication;"
```

### Perform Failover

```bash
# 1. Stop primary
docker stop pg-primary

# 2. Promote backup
docker exec pg-backup1 psql -U appuser -d appdb -c "SELECT pg_promote();"

# 3. Verify
psql -h localhost -p 5433 -U appuser -d appdb -c "SELECT pg_is_in_recovery();"
```

---

## 📁 File Structure

```
postgres-ha-complete-v2/
├── ha-nodes/
│   ├── primary/
│   │   ├── docker-compose.yml      # Primary configuration
│   │   └── init-primary.sql        # Initialization script
│   ├── backup1/
│   │   └── docker-compose.yml      # Backup1 configuration
│   └── backup2/
│       └── docker-compose.yml      # Backup2 configuration
├── ro-nodes/
│   ├── ro1/
│   ├── ro2/
│   └── ro3/
│   └── docker-compose.yml (x3)     # RO replica configs
├── monitoring/
│   ├── docker-compose.yml          # Prometheus, Grafana, Exporter
│   ├── prometheus.yml              # Metrics scrape config
│   └── provisioning/
│       ├── datasources/            # Grafana data sources
│       └── dashboards/             # Dashboard definitions
├── test-containers/
│   └── docker-compose.yml          # Write/Read/Validator tests
├── cluster-manager.ps1             # Setup/Test automation
└── TESTING_GUIDE.md                # Complete testing procedures
```

---

## 🧪 Testing Workflows

### Basic Sync Test

```bash
# Insert data on primary, verify all nodes see it
powershell -File cluster-manager.ps1 -Mode test
```

### Failover Test

```bash
# Simulate primary failure, promote backup, verify writes
powershell -File cluster-manager.ps1 -Mode failover
```

### Full Cluster Test

```bash
# Complete setup, sync check, status validation
powershell -File cluster-manager.ps1 -Mode all
```

### Continuous Testing

Create `test-loop.ps1`:
```powershell
while ($true) {
    & "cluster-manager.ps1" -Mode all
    Write-Host "Test cycle complete. Waiting 30 minutes..."
    Start-Sleep -Seconds 1800
}
```

Run: `powershell -File test-loop.ps1`

---

## 🔒 Security Configuration

### Network Security
- All nodes on isolated `ha-network` bridge
- No external port exposure except monitoring

### Database Users
```sql
-- appuser: Full database access
-- replicator: Replication-only access
-- Read-only role for RO replicas
```

### Connection Configuration
- pg_hba.conf: Allows local and replication connections
- SSL: Configurable in docker-compose files
- Password: Environment-based (configurable)

---

## 📈 Monitoring Dashboards

Access Grafana at http://localhost:3000

**Available Metrics**:
- Transaction rate (transactions/sec)
- Active connections per node
- Database size across nodes
- Replication lag between primary and standbys
- WAL activity
- Query performance

---

## 🔧 Troubleshooting

### Cluster Won't Start

```bash
# Check logs
docker logs pg-primary
docker logs pg-backup1

# Verify network
docker network inspect ha-network

# Clean restart
docker compose down -v
docker compose up -d
```

### Replication Lag High

```bash
# Check configuration
psql -h localhost -U appuser -d appdb \
  -c "SHOW wal_keep_size; SHOW max_wal_senders;"

# Monitor from logs
docker logs -f pg-primary | grep replication
```

### Node Out of Sync

```bash
# Stop and rebuild
docker stop pg-ro1
docker volume rm ro1_postgres_ro1_data
docker start pg-ro1
```

---

## 📖 Documentation

- **TESTING_GUIDE.md**: Comprehensive testing procedures
- **cluster-manager.ps1**: Automation script with inline help
- **docker-compose.yml files**: Service configuration details

---

## 🎓 Learning Path

1. **Setup**: Run `cluster-manager.ps1 -Mode setup`
2. **Explore**: Connect to each node, query tables
3. **Monitor**: Open Grafana dashboard
4. **Test**: Run `cluster-manager.ps1 -Mode test`
5. **Failover**: Practice failover scenarios
6. **Scale**: Add more RO replicas as needed

---

## 📞 Support

For issues or questions:

1. Check **TESTING_GUIDE.md** troubleshooting section
2. Review **docker-compose.yml** configurations
3. Check container logs: `docker logs <container-name>`
4. Monitor cluster status: `docker network inspect ha-network`

---

## 📝 Version History

- **v2.0** (2026-01-18): Complete HA cluster with 3 HA nodes + 3 RO replicas
- **v1.0** (2026-01-18): Initial setup with primary + 1 backup + 1 RO

---

**Last Updated**: 2026-01-18  
**Status**: Production-Ready
