# PostgreSQL HA Failover Guide - Bidirectional Replication

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL HA Cluster                      │
│                                                               │
│  Primary (Port 5432)                Secondary (Port 5435)   │
│  ├─ Streams WAL to:                 ├─ Alternative Primary   │
│  │  - Replica-1 (5433)              └─ Can promote to Master │
│  │  - Replica-2 (5434)              └─ Can replicate from    │
│  └─ Read/Write Operations               Primary              │
│                                                               │
│  Monitoring:                        Monitoring:              │
│  ├─ Exporter (9187)                 ├─ Exporter (9190)      │
│  └─ Prometheus (9090)               └─ Prometheus (9090)    │
│                                                               │
│  Replicas:                                                   │
│  ├─ Replica-1 (5433) - Read-only                            │
│  │  ├─ Exporter (9188)                                      │
│  │  └─ Replicates from Primary                              │
│  └─ Replica-2 (5434) - Read-only                            │
│     ├─ Exporter (9189)                                      │
│     └─ Replicates from Primary                              │
└─────────────────────────────────────────────────────────────┘
```

## Failover Scenarios

### Scenario 1: Primary Down → Promote Replica to Master

When `postgres-primary` fails:

```bash
# 1. Stop primary container
docker-compose stop postgres-primary

# 2. SSH into a replica container
docker exec -it postgres-replica-1 bash

# 3. Promote replica to primary
su - postgres
pg_ctl promote -D $PGDATA

# 4. Exit and verify
exit
docker exec postgres-replica-1 psql -U testadmin -d testdb -c "SELECT pg_is_in_recovery();"
# Should return: f (false = not in recovery, is now primary)

# 5. Update docker-compose.yml to replicate replicas from new primary
# Change replica-2 depends_on and command to point to postgres-replica-1

# 6. Restart replica-2 to stream from new primary
docker-compose restart postgres-replica-2

# 7. Optional: Promote original primary back when it comes online
# This requires demoting the intermediate primary first
```

### Scenario 2: Switch to Secondary Primary (Hot Standby)

Use `postgres-secondary` as the alternate master (pre-configured in docker-compose):

```bash
# 1. Start secondary with profile
docker-compose --profile secondary up -d postgres-secondary postgres-exporter-secondary

# 2. Check secondary status
docker exec postgres-secondary psql -U testadmin -d testdb -c "SELECT version();"

# 3. If you want to switch all traffic to secondary:
# - Update webserver environment: DB_HOST=postgres-secondary
# - Redirect replicas to secondary as new primary
# - Update application connection strings

# 4. Update docker-compose to use secondary as primary
sed -i 's/DB_HOST: postgres-primary/DB_HOST: postgres-secondary/g' docker-compose.yml

# 5. Restart webserver
docker-compose restart webserver
```

### Scenario 3: Graceful Switchover (Zero Downtime)

For planned maintenance on primary:

```bash
# 1. Ensure secondary is in sync with primary
docker exec postgres-secondary psql -U testadmin -d testdb -c "SELECT now();"

# 2. Run "CHECKPOINT" on primary to ensure WAL is written
docker exec postgres-primary psql -U testadmin -d testdb -c "CHECKPOINT;"

# 3. Stop writes to primary (in your application)
# - Pause application or update connection string to secondary

# 4. Promote secondary to new primary
docker exec postgres-secondary psql -U testadmin -d testdb -c "SELECT pg_promote();"

# 5. Wait a few seconds for promotion
sleep 5

# 6. Verify secondary is now accepting writes
docker exec postgres-secondary psql -U testadmin -d testdb -c "SELECT pg_is_in_recovery();"

# 7. Update application to use secondary as primary

# 8. Optional: Configure primary as replica of secondary for future failback
docker-compose down postgres-primary
# Modify docker-compose.yml to make primary replicate from secondary
# Then restart
```

## Connection Strings for Failover

### Primary (Default)
```
postgresql://testadmin:securepwd123@postgres-primary:5432/testdb
```

### Secondary (Alternate Primary)
```
postgresql://testadmin:securepwd123@postgres-secondary:5435/testdb
```

### Read-Only Replicas
```
# Replica-1 (for read-only queries)
postgresql://testadmin:securepwd123@postgres-replica-1:5433/testdb

# Replica-2 (for read-only queries)
postgresql://testadmin:securepwd123@postgres-replica-2:5434/testdb
```

### Load Balanced Read Pool (PgBouncer/HAProxy Required)
```
postgresql://testadmin:securepwd123@read-balancer:5432/testdb
```

## Monitoring During Failover

### Using Prometheus Queries

```promql
# Check replication lag on primary
pg_replication_lag_bytes{instance="primary"}

# Check secondary status
up{job="postgres-secondary"}

# Verify all replicas are connected
pg_replication_slots{instance="primary"}

# Monitor transaction lag on replicas
pg_stat_replication_delay_seconds
```

### Using Flask Dashboard

The webserver automatically detects:
- Primary role and WAL position
- Replica connectivity status
- Replication lag in bytes
- Row count synchronization

Access at: `http://localhost:5000`

## Automatic Failover Tools

For production environments, consider:

### 1. **Patroni** (Recommended for HA)
```bash
# Patroni automatically manages failover with etcd consensus
# Install: pip install patroni
```

### 2. **pg_auto_failover**
```bash
# Monitor-based automatic failover
# Install: https://github.com/citusdata/pg_auto_failover
```

### 3. **HAProxy + Custom Scripts**
```bash
# Load balance reads across replicas
# Custom health check scripts trigger failover
```

## Verification Checklist

After failover, verify:

- [ ] New primary accepts writes: `INSERT INTO users VALUES (default, 'test', now());`
- [ ] Replicas are replicating: `SELECT state FROM pg_stat_replication;`
- [ ] Row counts match: Compare primary vs replicas in dashboard
- [ ] Replication lag < 100ms: Check Prometheus `pg_replication_lag_bytes < 1000000`
- [ ] All services healthy: `docker-compose ps`
- [ ] Application connected to new primary
- [ ] Backups configured to new primary location

## Rollback to Original Configuration

```bash
# 1. Ensure original primary is online and healthy
docker-compose up -d postgres-primary

# 2. Wait for health checks (60 seconds)
sleep 60

# 3. Stop current primary (secondary)
docker-compose stop postgres-secondary

# 4. Reset replica-1 to stream from primary
docker-compose restart postgres-replica-1

# 5. Reset replica-2 to stream from primary
docker-compose restart postgres-replica-2

# 6. Update webserver to point back to primary
sed -i 's/DB_HOST: postgres-secondary/DB_HOST: postgres-primary/g' docker-compose.yml
docker-compose restart webserver

# 7. Verify replication
docker exec postgres-primary psql -U testadmin -d testdb -c "SELECT * FROM pg_stat_replication;"
```

## Performance Tuning During Failover

```sql
-- On the new primary, optimize for write performance
ALTER SYSTEM SET synchronous_commit = local;
ALTER SYSTEM SET shared_buffers = '4GB';
ALTER SYSTEM SET effective_cache_size = '12GB';
SELECT pg_reload_conf();
```

## Disaster Recovery Plan

1. **Backup Strategy**: WAL archiving to S3/Azure
2. **PITR Capability**: Point-in-time recovery to any point in last 30 days
3. **Secondary Datacenter**: Replicate to geographic standby
4. **Regular Drills**: Test failover quarterly

## Quick Reference

| Scenario | Command | Time |
|----------|---------|------|
| Promote Replica-1 | `pg_ctl promote -D $PGDATA` | 5-10 seconds |
| Switch to Secondary | `sed -i 's/primary/secondary/g'` + restart | 10-30 seconds |
| Graceful Switchover | All steps above | 5-10 minutes |
| Full Failover + Verify | All checks | 20-30 minutes |

