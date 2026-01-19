# PostgreSQL HA Cluster - Quick Reference

## 🚀 Start/Stop Cluster

**Start everything:**
```bash
cd c:\Users\reven\docker\postgres-ha-complete-v2
docker compose up -d              # HA nodes
docker compose up -d -f monitoring/docker-compose.yml  # Monitoring
docker compose up -d -f test-containers/docker-compose.yml  # Tests
```

**Stop everything:**
```bash
docker compose down -f test-containers/docker-compose.yml
docker compose down -f monitoring/docker-compose.yml
docker compose down
```

## 📊 Check Status

**All containers:**
```bash
docker compose ps
```

**Cluster health:**
```bash
docker exec pg-primary psql -U appuser -d appdb \
  -c "SELECT client_addr, state FROM pg_stat_replication;"
```

**View validator (live sync check):**
```bash
docker logs -f pg-validator | tail -30
```

**Row count on all nodes:**
```bash
docker exec pg-primary psql -U appuser -d appdb \
  -c "SELECT COUNT(*) FROM test_replication;"
```

## 🎯 Connection Strings

| Node | Connection | Purpose |
|------|-----------|---------|
| Primary | `postgresql://appuser:apppass@localhost:5432/appdb` | Writes |
| Backup1 | `postgresql://appuser:apppass@localhost:5433/appdb` | Read-Only |
| Backup2 | `postgresql://appuser:apppass@localhost:5434/appdb` | Read-Only |
| RO1 | `postgresql://appuser:apppass@localhost:5440/appdb` | Read-Only Scale |
| RO2 | `postgresql://appuser:apppass@localhost:5441/appdb` | Read-Only Scale |
| RO3 | `postgresql://appuser:apppass@localhost:5442/appdb` | Read-Only Scale |

## 📈 Dashboards

- **Grafana:** http://localhost:3000 (admin/admin)
- **Prometheus:** http://localhost:9090/targets

## 🧪 Test Commands

**Insert data to primary:**
```bash
docker exec pg-primary psql -U appuser -d appdb <<EOF
INSERT INTO test_replication (message, node_id) 
VALUES ('Test data', 'primary');
EOF
```

**Check sync on RO nodes:**
```bash
for port in 5440 5441 5442; do
  echo "Port $port:"
  psql -h localhost -p $port -U appuser -d appdb -c "SELECT COUNT(*) FROM test_replication;"
done
```

**Monitor replication lag:**
```bash
docker exec pg-primary psql -U appuser -d appdb -c \
  "SELECT 
    client_addr, 
    backend_start, 
    backend_xmin, 
    state_change 
  FROM pg_stat_replication;"
```

**Check slot status:**
```bash
docker exec pg-primary psql -U appuser -d appdb -c \
  "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

## 🔍 Troubleshooting

**Check node logs:**
```bash
docker logs pg-primary      # Primary
docker logs pg-backup1      # Backup 1
docker logs pg-ro1         # Read-Only 1
```

**Test network connectivity:**
```bash
docker exec pg-primary ping pg-backup1
docker exec pg-primary psql -h pg-ro1 -U appuser -d appdb -c "SELECT 1;"
```

**View pg_basebackup progress:**
```bash
docker logs pg-backup1 | grep "base backup"
```

**Check disk usage:**
```bash
docker exec pg-primary du -sh /var/lib/postgresql/data
```

## 📝 Test Scenarios

### Scenario 1: Continuous Write & Read
The cluster continuously:
- Writes 1 row per second to primary (pg-writer)
- Reads from all 3 RO nodes in rotation (pg-reader)
- Validates sync every 10 seconds (pg-validator)

Monitor with: `docker logs -f pg-validator`

### Scenario 2: Primary Failure Recovery
When primary fails:
1. One backup node can be promoted to primary
2. Other replicas will follow new primary
3. RO nodes automatically reconnect

Promote backup1 to primary:
```bash
docker exec pg-backup1 psql -U appuser -d appdb \
  -c "SELECT pg_promote();"
```

### Scenario 3: Read Load Balancing
Distribute reads across RO replicas:
- RO1 (5440): Consumer A
- RO2 (5441): Consumer B  
- RO3 (5442): Consumer C

All get consistent data with minimal lag.

## 💾 Data Persistence

All data stored in Docker volumes:
```
postgres_primary_data       # Primary node data
postgres_backup1_data       # Backup 1 data
postgres_backup2_data       # Backup 2 data
postgres_ro1_data          # RO1 data
postgres_ro2_data          # RO2 data
postgres_ro3_data          # RO3 data
```

View volumes:
```bash
docker volume ls | grep postgres
```

## 🔐 Security Notes

**Production Recommendations:**
- [ ] Change default passwords (apppass, replpass)
- [ ] Enable SSL/TLS for connections
- [ ] Configure firewall rules
- [ ] Limit network access to pg_hba.conf
- [ ] Use strong passwords for pg_hba.conf auth
- [ ] Monitor pg_log for suspicious activity
- [ ] Implement connection pooling (pgBouncer)
- [ ] Set up audit logging

**Credentials (Change Before Production):**
- appuser password: `apppass`
- replicator password: `replpass`

## 🎓 Key Metrics to Monitor

| Metric | Query | Purpose |
|--------|-------|---------|
| WAL LSN | `pg_last_wal_receive_lsn()` | Track replication progress |
| Rep Lag | `EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))` | Replication delay in seconds |
| Active Connections | `SELECT count(*) FROM pg_stat_activity;` | Connection count |
| Cache Hit | `SELECT sum(heap_blks_hit)/(sum(heap_blks_hit)+sum(heap_blks_read))` | Cache efficiency |

## 📞 Support Commands

**Full cluster report:**
```bash
echo "=== Cluster Status ===" && \
docker compose ps && \
echo -e "\n=== Replication Status ===" && \
docker exec pg-primary psql -U appuser -d appdb -c \
  "SELECT client_addr, state FROM pg_stat_replication;" && \
echo -e "\n=== Test Data Count ===" && \
docker exec pg-primary psql -U appuser -d appdb -c \
  "SELECT COUNT(*) FROM test_replication;"
```

**Health check (all nodes):**
```bash
for svc in pg-primary pg-backup1 pg-backup2 pg-ro1 pg-ro2 pg-ro3 etcd-primary; do
  echo -n "$svc: "
  docker exec $svc pg_isready -U appuser 2>/dev/null && echo "✓" || echo "✗"
done
```

---

**Last Updated:** 2026-01-18  
**Cluster:** PostgreSQL 15.15  
**Status:** ✅ Operational
