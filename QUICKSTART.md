# Quick Start - PostgreSQL Cluster Test

## TL;DR - Run Test in 3 Steps

### Step 1: Clean Environment
```powershell
cd "C:\Users\reven\docker\postgreSQL"
docker-compose down -v
```

### Step 2: Start Services
```powershell
docker-compose up -d
Start-Sleep -Seconds 30
```

### Step 3: Run Test
```powershell
powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
```

**Total Time:** ~7 minutes ⏱️

---

## What the Test Does

```
✓ Validates 7 containers are healthy
✓ Makes node2 primary (step 2 in ~40s)
✓ Initializes database with schema
✓ Records baseline entry count
✓ Generates ~300 test entries (5 minutes)
✓ Records final entry count
✓ Promotes node1 to primary (step 7 in ~40s)
✓ Validates data replicated correctly
```

---

## Expected Output

```
======================================================================
  COMPREHENSIVE POSTGRESQL CLUSTER TEST
======================================================================

[1/7] Validating Container Health
   [OK] postgres-node1 : running
   [OK] postgres-node2 : running
   [OK] postgres-node3 : running
   [OK] operationManagement : running

[2/7] Promoting node2 to PRIMARY
   [INFO] Sending promotion request...
   [OK] Request sent (may timeout, operation continues)
   [INFO] Waiting 40 seconds for promotion to complete...
   Current Cluster State:
      Primary: node2
      node1 : [STANDBY]
      node2 : [PRIMARY]
      node3 : [STANDBY]

[3/7] Initializing Database with Test Data
   [INFO] Running init container...
   [OK] Database initialized successfully ✓

[4/7] Validating Entry Count - Before Test Data Generation
   [OK] node1 has 0 entries
   [OK] node2 has 0 entries
   [OK] node3 has 0 entries

[5/7] Starting Test Data Generator
   [INFO] Running test data generator (300 seconds)...
   [OK] Test data generator completed ✓

[6/7] Validating Entry Count - After Test Data Generation
   [OK] node1 has 314 entries
   [OK] node2 has 314 entries
   [OK] node3 has 314 entries

[7/7] Promoting node1 to PRIMARY
   [INFO] Sending promotion request...
   [OK] Request sent (may timeout, operation continues)
   [INFO] Waiting 40 seconds for promotion to complete...
   Current Cluster State:
      Primary: node1
      node1 : [PRIMARY]
      node2 : [STANDBY]
      node3 : [STANDBY]

[8/8] Validating Data Replication
   Data must be consistent across all nodes after promotion
   [OK] node1 has 314 entries
   [OK] node2 has 314 entries
   [OK] node3 has 314 entries
   [OK] Data is consistent across all nodes ✓

======================================================================
TEST COMPLETE
   [OK] All tests completed successfully ✓
======================================================================
```

---

## If It Fails

| Problem | Solution |
|---------|----------|
| Connection refused | `docker-compose ps` then `Start-Sleep 30` |
| psql not found | `winget install PostgreSQL.PostgreSQL.16` |
| Init fails | `docker-compose --profile init logs db-init` |
| Data gen fails | `docker-compose --profile test logs test-data-generator-node2` |
| Promotion times out | `docker-compose logs operationManagement` |
| All nodes standby | Wait 30s, sometimes takes longer |

---

## Ports & Credentials

```
Node1: localhost:5432
Node2: localhost:5435
Node3: localhost:5436

User: testadmin
Pass: securepwd123
DB: testdb
```

---

## Check Status Manually

```powershell
# Show current primary
$r = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status" -UseBasicParsing
$r.Content | ConvertFrom-Json | ConvertTo-Json

# Count entries on node1
psql -h localhost -p 5432 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

# List containers
docker-compose ps
```

---

## Full Documentation

📖 See **TEST_RESTART.md** for complete troubleshooting guide  
📋 See **COMPREHENSIVE_TEST_SUMMARY.md** for detailed architecture

---

✨ **That's it! Good luck!**
