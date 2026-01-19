# Comprehensive Test Suite - Complete Resource Index

## 📋 Quick Reference

### Test Files
- **comprehensive_test.ps1** - Main automated test script
- **test.ps1** - Simple test version (legacy)
- **test_sequence.ps1** - Step-by-step sequence (legacy)
- **test_status_sequence.ps1** - Status tracking version (legacy)

### Documentation Files
- **QUICKSTART.md** - 3-step quick start guide
- **TEST_RESTART.md** - Complete restart instructions (120+ lines)
- **COMPREHENSIVE_TEST_SUMMARY.md** - Detailed architecture and implementation
- **ARCHITECTURE_FLOW_DIAGRAM.md** - Visual diagrams and state transitions
- **README_TEST_RESOURCES.md** - This file

### Configuration Files
- **docker-compose.yml** - Container orchestration (245 lines)
- **Dockerfile.init** - Database initialization container
- **Dockerfile.testgen** - Test data generator container
- **Dockerfile.replica** - PostgreSQL standby/replica container
- **Dockerfile.operationManagement** - REST API container
- **init.sql** - Database schema and initial data
- **init-database.sh** - Shell initialization script
- **test_data_generator.py** - Python data generation script

---

## 📂 File Locations

```
C:\Users\reven\docker\postgreSQL\
├── comprehensive_test.ps1 ..................... Main test script ⭐
├── QUICKSTART.md ............................ 3-step guide ⭐
├── TEST_RESTART.md .......................... Full documentation ⭐
├── COMPREHENSIVE_TEST_SUMMARY.md ........... Detailed summary ⭐
├── ARCHITECTURE_FLOW_DIAGRAM.md ........... Visual diagrams ⭐
├── README_TEST_RESOURCES.md ............... This file ⭐
│
├── docker-compose.yml ...................... Container config
├── Dockerfile.init ......................... Init container
├── Dockerfile.testgen ...................... Test generator
├── Dockerfile.replica ...................... Standby container
├── Dockerfile.operationManagement ......... API container
├── Dockerfile.primary ...................... Primary container
├── Dockerfile.webserver .................... Web UI container
│
├── init.sql ............................... SQL schema
├── init-database.sh ....................... Init script
├── test_data_generator.py ................. Data generator
├── operationManagement.py ................. REST API
├── webserverapp.py ........................ Web UI
│
├── test.ps1 ............................... Simple test (legacy)
├── test_sequence.ps1 ...................... Sequence test (legacy)
├── test_status_sequence.ps1 ............... Status test (legacy)
│
├── pg_hba_replication.conf ............... Replication config
├── replication.conf ....................... Replication settings
├── prometheus.yml ......................... Monitoring config
├── requirements.txt ....................... Python dependencies
│
└── templates/
    └── index.html ......................... Web UI template
```

---

## 🚀 Quick Start

### One-Liner Start Test
```powershell
cd "C:\Users\reven\docker\postgreSQL"; docker-compose down -v; docker-compose up -d; Start-Sleep 30; powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
```

### Step-by-Step
```powershell
# 1. Clean environment
cd "C:\Users\reven\docker\postgreSQL"
docker-compose down -v

# 2. Start services
docker-compose up -d
Start-Sleep -Seconds 30

# 3. Run test
powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
```

**Time Required:** ~7 minutes ⏱️

---

## 📊 Test Coverage

The comprehensive test validates:

### Container Management
✓ Docker-compose up/down  
✓ Container health checks  
✓ Service readiness  
✓ Network connectivity  

### Database Operations
✓ Schema initialization  
✓ Data insertion  
✓ Query execution  
✓ Table verification  

### Replication
✓ Data synchronization  
✓ Replication lag monitoring  
✓ Consistency validation  
✓ Multi-node replication  

### Cluster Management
✓ Node promotion (primary selection)  
✓ Node demotion (standby mode)  
✓ Automatic failover  
✓ State transitions  

### Data Integrity
✓ Entry count tracking  
✓ Data persistence  
✓ Consistency across nodes  
✓ No data loss during failover  

### API Functionality
✓ Status endpoint  
✓ Promote endpoint  
✓ Demote endpoint  
✓ Timeout handling  

---

## 📈 Test Metrics

| Metric | Value | Unit |
|--------|-------|------|
| **Total Duration** | 435 | seconds (~7 min) |
| **Container Startup** | 30-60 | seconds |
| **Node Promotion** | 40 | seconds (per operation) |
| **Database Init** | 10-20 | seconds |
| **Data Generation** | 300 | seconds (5 min) |
| **Entries Generated** | ~300 | records |
| **Replication Lag** | <1 | second |
| **Containers Tested** | 7 | services |
| **Nodes Tested** | 3 | primary nodes |
| **Test Steps** | 8 | major phases |
| **Success Criteria** | 100% | pass rate target |

---

## 🔍 What Each File Does

### comprehensive_test.ps1
**Purpose:** Complete automated test harness  
**Language:** PowerShell  
**Execution:** ~7 minutes  
**Key Functions:**
- `Test-AllContainersHealthy()` - Validates docker-compose status
- `Set-NodePrimary()` - Promotes node to primary
- `Initialize-Database()` - Creates schema and initial data
- `Get-EntryCount()` - Queries message table count
- `Start-TestDataGenerator()` - Runs 5-minute data generation
- `Validate-DataReplication()` - Checks consistency
- `Show-ClusterStatus()` - Displays current state

### QUICKSTART.md
**Purpose:** 3-step quick reference  
**Content:**
- Commands to start test
- Expected output example
- Troubleshooting (quick)
- Credentials reference
- 3-4 pages

### TEST_RESTART.md
**Purpose:** Complete operational guide  
**Content:**
- Prerequisites and checklist
- 2 methods to run test (automated & manual)
- Timeline breakdown
- Success criteria
- 7 troubleshooting scenarios with solutions
- CI/CD integration example
- Advanced debugging options
- 120+ lines, 10+ sections

### COMPREHENSIVE_TEST_SUMMARY.md
**Purpose:** Technical documentation  
**Content:**
- File-by-file description
- Function documentation
- Database operations guide
- Service names and ports
- API endpoints reference
- Entry count tracking
- Sample SQL queries
- Docker commands
- Performance expectations
- 300+ lines, detailed

### ARCHITECTURE_FLOW_DIAGRAM.md
**Purpose:** Visual architecture  
**Content:**
- ASCII cluster topology diagram
- Test timeline with durations
- Data flow during each phase
- State transition diagrams
- Container boot order
- Success criteria matrix
- Network topology diagram
- 400+ lines, highly visual

### docker-compose.yml
**Purpose:** Container orchestration  
**Key Services:**
- postgres-node1/2/3 (primary/standby)
- postgres-replica-1/2 (standby only)
- operationManagement (API on 5001)
- postgres-webserver (UI on 5000)
- db-init (schema creation, profile: init)
- test-data-generator-node1/2/3 (profile: test)

### Dockerfile files
- **Dockerfile.init** - Runs init.sql and init-database.sh
- **Dockerfile.testgen** - Runs test_data_generator.py
- **Dockerfile.replica** - PostgreSQL standby image
- **Dockerfile.operationManagement** - Flask API
- **Dockerfile.primary** - PostgreSQL primary image
- **Dockerfile.webserver** - Web UI container

### init-database.sh
**Purpose:** Database initialization script  
**Actions:**
- Waits for database availability
- Creates testdb database
- Creates messages table
- Inserts initial test data
- Verifies replication

### test_data_generator.py
**Purpose:** Generate test data  
**Behavior:**
- Connects to assigned node
- Inserts random messages
- Runs for 5 minutes (300 seconds)
- ~1 entry per second
- Handles database errors gracefully

### operationManagement.py
**Purpose:** REST API for cluster management  
**Endpoints:**
- GET /status - Current cluster state
- POST /promote/{node} - Promote node to primary
- POST /demote-all - Demote all to standby
- Auto-demote before promotion

### init.sql
**Purpose:** Database schema  
**Creates:**
- testdb database
- messages table (id, message, created_at)
- users table (optional)
- logs table (optional)
- Indexes on common queries

---

## 🎯 Test Scenarios Covered

### Scenario 1: Container Lifecycle
```
Start → Health Check → All Running → ✓
```

### Scenario 2: Primary Node Promotion
```
All Standby → Promote node2 → node2 Primary, others Standby → ✓
```

### Scenario 3: Schema Initialization
```
Init Container → Create Tables → Verify Exist → ✓
```

### Scenario 4: Data Replication (5 minutes)
```
Generator Start → 300 entries → Replicate to all nodes → Verify count → ✓
```

### Scenario 5: Primary Failover
```
node2 Primary → Promote node1 → Auto-demote node2 → node1 Primary → ✓
```

### Scenario 6: Data Persistence
```
Before failover: 300 entries → After failover: 300 entries → ✓
```

### Scenario 7: Consistency Check
```
node1: 300 → node2: 300 → node3: 300 → All equal → ✓
```

---

## 🛠️ Useful Commands

### Check Status
```powershell
# Get current primary
$r = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status" -UseBasicParsing
$r.Content | ConvertFrom-Json | ConvertTo-Json
```

### Query Database
```bash
# Count entries on node2 (primary)
psql -h localhost -p 5435 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

# List recent entries
psql -h localhost -p 5435 -U testadmin -d testdb -c "SELECT * FROM messages LIMIT 10;"
```

### Container Management
```bash
# View all containers
docker-compose ps

# Check specific service logs
docker-compose logs operationManagement --tail=50

# Restart service
docker-compose restart postgres-node1

# Full cleanup
docker-compose down -v
```

### Manual Promotion
```powershell
# Make node1 primary
Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/node1" `
    -Method POST -UseBasicParsing -TimeoutSec 180

# Demote all to standby
Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/demote-all" `
    -Method POST -UseBasicParsing -TimeoutSec 180
```

---

## 📖 Documentation Hierarchy

```
README_TEST_RESOURCES.md (You are here)
├─ For Overview & Navigation
│
├── QUICKSTART.md
│  └─ For: "Just run it quickly"
│  └─ Read if: First time users
│
├── TEST_RESTART.md
│  └─ For: Detailed instructions
│  └─ Read if: Need step-by-step guide
│
├── COMPREHENSIVE_TEST_SUMMARY.md
│  └─ For: Technical deep dive
│  └─ Read if: Debugging or integration
│
└── ARCHITECTURE_FLOW_DIAGRAM.md
   └─ For: Visual understanding
   └─ Read if: Learning the system
```

---

## ⚠️ Common Issues & Solutions

| Issue | Solution | File |
|-------|----------|------|
| "Connection refused" | `Start-Sleep 30` then retry | QUICKSTART |
| Test fails on step 3 | Check `docker-compose --profile init logs db-init` | TEST_RESTART |
| Data not generating | Check `docker-compose --profile test logs test-data-generator-node2` | TEST_RESTART |
| Promotion times out | Normal (504), operation continues in background | COMPREHENSIVE_TEST |
| All nodes show standby | Wait 30+ seconds, check logs | TEST_RESTART |
| psql not found | Install: `winget install PostgreSQL.PostgreSQL.16` | QUICKSTART |
| Docker network issues | Check: `docker network inspect postgresql_app-network` | TEST_RESTART |

---

## 🎓 Learning Path

### For Beginners
1. Read: QUICKSTART.md (5 min)
2. Run: comprehensive_test.ps1 (7 min)
3. Observe: Output and status messages
4. Success: See all ✓ marks

### For Operators
1. Read: TEST_RESTART.md (15 min)
2. Understand: Test sequence timeline
3. Learn: Troubleshooting section
4. Practice: Manual test execution

### For Developers
1. Read: COMPREHENSIVE_TEST_SUMMARY.md (30 min)
2. Study: Test functions in PowerShell script
3. Review: Docker files and Python code
4. Extend: Modify test criteria or add steps

### For Architects
1. Read: ARCHITECTURE_FLOW_DIAGRAM.md (20 min)
2. Understand: Network topology and data flow
3. Review: State transitions and boot order
4. Design: Similar tests for your infrastructure

---

## 📞 Support Resources

### If test fails:
1. Check: `docker-compose ps`
2. Review: Container logs
3. Consult: TEST_RESTART.md troubleshooting
4. Verify: Prerequisites are met

### If you have questions:
1. Check: COMPREHENSIVE_TEST_SUMMARY.md for details
2. Review: API endpoint documentation
3. Examine: Docker container configurations
4. Study: Sample SQL queries section

### For advanced issues:
1. Enable: Verbose logging in containers
2. Monitor: Real-time replication status
3. Capture: Detailed metrics
4. Analyze: Complete logs from all services

---

## 🏆 Success Indicators

✅ **Quick success:** All 8 steps complete in ~7 minutes  
✅ **Data generation:** ~300 entries inserted without errors  
✅ **Replication:** All nodes have identical entry counts  
✅ **Failover:** Primary transitions successfully  
✅ **Consistency:** No data loss during promotion  
✅ **API:** All endpoints responding correctly  
✅ **Containers:** All services healthy and running  

---

## 📅 Version Information

- **Created:** January 16, 2026
- **PostgreSQL:** 14.2
- **Python:** 3.11
- **PowerShell:** 5.1+ / 7.0+
- **Docker Compose:** 3.8+
- **Test Duration:** ~7 minutes
- **Target Success Rate:** 95-100%

---

## 📋 Checklist Before Running

- [ ] Docker and Docker Compose installed
- [ ] Windows PowerShell 5.1+ or PowerShell 7+
- [ ] PostgreSQL client tools (psql) installed
- [ ] Docker has sufficient disk space (2GB recommended)
- [ ] No services running on ports 5000-5436
- [ ] Read QUICKSTART.md at minimum
- [ ] Internet connection (for pulling images)
- [ ] Administrator privileges for Docker operations

---

## ✨ That's Everything!

You now have:
- ✅ Complete automated test script
- ✅ 5 comprehensive documentation files
- ✅ Visual diagrams and flow charts
- ✅ Troubleshooting guides
- ✅ Command reference
- ✅ Expected output examples

**Start here:** QUICKSTART.md  
**Run this:** comprehensive_test.ps1  
**If stuck:** TEST_RESTART.md → Troubleshooting section  

---

**Last Updated:** January 16, 2026  
**Total Documentation:** 1500+ lines across 5 files  
**Test Coverage:** 8 major phases, 7 services, comprehensive validation
