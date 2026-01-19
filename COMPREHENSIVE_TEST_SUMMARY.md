# Comprehensive Test Suite - Implementation Summary

## Files Created/Modified

### 1. **comprehensive_test.ps1** (NEW)
Complete automated test script for PostgreSQL cluster management.

**Features:**
- ✓ Pre-flight checks (validates all containers are healthy)
- ✓ Primary node promotion (node2 → primary)
- ✓ Database initialization (creates schema and initial data)
- ✓ Entry count validation (before and after data generation)
- ✓ Automated test data generation (5-minute data insertion)
- ✓ Primary node failover (node1 → primary)
- ✓ Data replication validation (consistency checks)
- ✓ Comprehensive status reporting with color-coded output

**Key Functions:**
- `Test-AllContainersHealthy()` - Validates container status
- `Set-NodePrimary()` - Promotes node to primary role
- `Initialize-Database()` - Initializes schema and test data
- `Get-EntryCount()` - Queries message table entry count
- `Validate-EntryCount()` - Validates data at specific phases
- `Start-TestDataGenerator()` - Runs 5-minute data generation
- `Validate-DataReplication()` - Ensures data consistency across nodes
- `Show-ClusterStatus()` - Displays current cluster state

**Usage:**
```powershell
cd "C:\Users\reven\docker\postgreSQL"
powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
```

**Expected Duration:** ~7 minutes

---

### 2. **TEST_RESTART.md** (NEW)
Complete guide for running, troubleshooting, and maintaining the test suite.

**Sections:**
1. **Overview** - What the test does
2. **Prerequisites** - Required tools and permissions
3. **Pre-Test Checklist** - Steps to clean and prepare environment
4. **Running the Test** - Two methods (automated script and manual)
5. **Expected Timeline** - Phase breakdown with durations
6. **Test Success Criteria** - What success looks like
7. **Troubleshooting** - 7 common issues with solutions
8. **Clean Up** - Post-test cleanup options
9. **Running Tests Repeatedly** - Loop execution for regression testing
10. **CI/CD Integration** - GitHub Actions example workflow
11. **Advanced Debugging** - Monitoring and logging options
12. **Support** - Further resources

**Key Information:**
- Service names: `db-init` (not `postgres-init`), `test-data-generator-node2` (with `--profile test`)
- Database credentials: testadmin / securepwd123 / testdb
- Node ports: node1=5432, node2=5435, node3=5436
- Test timeline: 435 seconds (~7 minutes)
- Data generation: ~300 entries over 5 minutes
- Success criteria: 100% container health, data consistency, successful failover

---

## Test Sequence Workflow

```
Step 1: Container Health Check (30-60s)
    ↓
Step 2: Promote node2 to PRIMARY (40s)
    ↓ [Show cluster status: node2 is primary]
    ↓
Step 3: Initialize Database (10-20s)
    ↓ [Create schema, tables, initial data]
    ↓
Step 4: Validate Initial Entry Count
    ↓ [Query message count on all nodes]
    ↓
Step 5: Start Test Data Generator (300s = 5 minutes)
    ↓ [Insert ~300 random entries]
    ↓
Step 6: Validate Final Entry Count
    ↓ [Query updated message count]
    ↓
Step 7: Promote node1 to PRIMARY (40s)
    ↓ [Automatic demote-all → promote node1]
    ↓ [Show cluster status: node1 is primary, others standby]
    ↓
Step 8: Validate Data Replication
    ↓ [Verify entry count is consistent across all nodes]
    ↓
✓ TEST COMPLETE (435s total)
```

---

## Database Operations

### Entry Count Tracking
- **Before data generation:** Query initial count (typically 0-100)
- **After generation:** Query final count (initial + ~300)
- **After failover:** Verify count remains consistent

### Connection Details
```
Node1: localhost:5432  (primary after step 7)
Node2: localhost:5435  (primary after step 2)
Node3: localhost:5436  (standby throughout)

User: testadmin
Password: securepwd123
Database: testdb
Table: messages
```

### Sample Queries
```sql
-- Count entries
SELECT COUNT(*) FROM messages;

-- List recent entries
SELECT id, message, created_at FROM messages ORDER BY created_at DESC LIMIT 10;

-- Check replication status
SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;

-- Verify primary status
SELECT pg_is_in_recovery();  -- false = primary, true = standby
```

---

## Container Service Names

### Core Services
- `postgres-node1` - Primary/Standby (port 5432)
- `postgres-node2` - Primary/Standby (port 5435)
- `postgres-node3` - Primary/Standby (port 5436)
- `postgres-replica-1` - Standby (port 5433)
- `postgres-replica-2` - Standby (port 5434)
- `operationManagement` - Cluster management API (port 5001)
- `postgres-webserver` - Web UI (port 5000)

### One-Time Services (with profiles)
- `db-init` - Database initialization (requires `--profile init`)
- `test-data-generator-node1` - Data generator for node1 (requires `--profile test`)
- `test-data-generator-node2` - Data generator for node2 (requires `--profile test`)
- `test-data-generator-node3` - Data generator for node3 (requires `--profile test`)

### Docker Compose Commands
```bash
# Start all core services
docker-compose up -d

# Initialize database
docker-compose --profile init run --rm db-init

# Generate test data
docker-compose --profile test run --rm test-data-generator-node2

# Check specific service logs
docker-compose logs operationManagement --tail=50
docker-compose logs postgres-node1 --tail=50
```

---

## API Endpoints Used

### Cluster Management API (port 5001)

**Get Status**
```
GET /api/operationmanagement/status
Response: {"nodes": {"node1": {"is_primary": false}, ...}}
```

**Promote Node**
```
POST /api/operationmanagement/promote/{node}
Timeout: ~40s (includes auto-demote-all before promotion)
Response: 200 or 504 (504 = normal timeout, operation continues)
```

**Demote All**
```
POST /api/operationmanagement/demote-all
Timeout: ~20s (demotes all nodes to standby)
Response: 200 or 504 (504 = normal timeout, operation continues)
```

**Get Node Status**
```
GET /api/operationmanagement/status
Returns: Current primary node and standby status for all nodes
```

---

## Success Indicators

### Container Health
✓ All 7 services show "Up" status
✓ All services have healthy health checks
✓ No container errors in logs

### Promotion Success
✓ Node status changes from standby to primary
✓ Promotion API returns 200 or 504 (both acceptable)
✓ Status API shows correct primary node

### Data Consistency
✓ Entry count increases during 5-minute generation (~300 entries)
✓ Entry count is identical on all nodes after replication
✓ No data loss after node promotion

### Replication
✓ Standby nodes receive updates from primary within 1 second
✓ All nodes show same entry count
✓ No replication lag or sync issues in logs

---

## Performance Expectations

| Metric | Value | Notes |
|--------|-------|-------|
| Container Startup | 30-60s | Initial database initialization |
| Node Promotion | 40s | Includes 5s stabilization + promotion |
| Database Init | 10-20s | Schema creation and initial data |
| Data Generation | 300s | ~1 entry per second over 5 minutes |
| Total Test Duration | 435s (~7min) | Full sequence start to finish |
| Replication Lag | <1s | Data visible on standbys within 1 second |
| Entry Count Growth | +300 | 5-minute generation inserts ~300 entries |

---

## Troubleshooting Workflow

### If test fails:

1. **Check containers are running**
   ```powershell
   docker-compose ps
   ```

2. **Check API is responding**
   ```powershell
   Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status"
   ```

3. **Check database connectivity**
   ```bash
   psql -h localhost -p 5435 -U testadmin -d testdb -c "SELECT 1;"
   ```

4. **Review logs**
   ```bash
   docker-compose logs operationManagement
   docker-compose logs postgres-node2
   ```

5. **Clean and retry**
   ```bash
   docker-compose down -v
   docker-compose up -d
   Start-Sleep -Seconds 30
   powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
   ```

---

## Next Steps

1. Run `comprehensive_test.ps1` to execute full test suite
2. Monitor output for any failures or warnings
3. If successful, data is replicated across all nodes
4. If failures occur, use TEST_RESTART.md troubleshooting section
5. Inspect logs: `docker-compose logs <service>`
6. Clean up: `docker-compose down` or `docker-compose down -v`

---

**Created:** January 16, 2026  
**PostgreSQL Version:** 14.2  
**Test Framework:** PowerShell 5.1+ / PowerShell 7+  
**Test Duration:** ~7 minutes  
**Success Criteria:** All 8 validation steps pass
