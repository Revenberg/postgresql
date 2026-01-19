# PostgreSQL Cluster Test - Visual Architecture & Flow

## Cluster Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     POSTGRESQL CLUSTER                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
│  │   postgres-node1 │  │   postgres-node2 │  │   postgres-node3 │
│  │                  │  │                  │  │                  │
│  │  Port: 5432      │  │  Port: 5435      │  │  Port: 5436      │
│  │  Status: STANDBY │  │  Status: PRIMARY │  │  Status: STANDBY │
│  │  Role: Replica   │  │  Role: Primary   │  │  Role: Replica   │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘
│         |                      |                      |
│         └──────────────────────|──────────────────────┘
│                                |
│                   (Replication Stream)
│                                |
│  ┌──────────────────┐  ┌──────────────────┐
│  │  postgres-       │  │  postgres-       │
│  │  replica-1       │  │  replica-2       │
│  │                  │  │                  │
│  │  Port: 5433      │  │  Port: 5434      │
│  │  Status: STANDBY │  │  Status: STANDBY │
│  └──────────────────┘  └──────────────────┘
│
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                      MANAGEMENT SERVICES                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │         operationManagement API (Port 5001)                │ │
│  │  - Status: GET /status                                     │ │
│  │  - Promote: POST /promote/{node}                          │ │
│  │  - Demote-All: POST /demote-all                           │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │      postgres-webserver (Port 5000)                         │ │
│  │  - Web UI for cluster visualization                         │ │
│  │  - Manual promotion controls                               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                     TEST INFRASTRUCTURE                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │           db-init (Profile: init)                          │ │
│  │  - Creates schema with init.sql                            │ │
│  │  - Initializes tables: messages, users, logs              │ │
│  │  - Runs once per test cycle                               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │    test-data-generator-node1/2/3 (Profile: test)          │ │
│  │  - Connects to assigned node                               │ │
│  │  - Inserts random test data for 5 minutes                  │ │
│  │  - Generates ~300 entries (1 per second)                   │ │
│  │  - Validates replication to other nodes                    │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Test Sequence Timeline

```
TIME    STEP  ACTION                              STATUS
────────────────────────────────────────────────────────────

0s      1     Container Health Check
             └─ docker-compose ps                  ✓ All UP
             └─ Verify health checks               ✓ Healthy

30s     2     Promote node2 to PRIMARY
             ├─ POST /api/promote/node2            → Sent
             ├─ Auto-demote all nodes              ~ 15s
             ├─ Promote node2                      ~ 10s
             ├─ Reconfigure standbys               ~ 15s
             └─ Verify status                      ✓ node2=PRIMARY

70s     3     Initialize Database
             ├─ Run db-init container             ~ 10s
             ├─ Execute init.sql                  ~ 5s
             ├─ Create schema                     ~ 5s
             └─ Verify tables exist               ✓ Created

100s    4     Validate Initial Entry Count
             ├─ Query node1                       0 entries
             ├─ Query node2                       0 entries
             └─ Query node3                       0 entries
                                                  ✓ Baseline

105s    5     Start Test Data Generator
             ├─ Run test-data-generator-node2    ~ 5min
             ├─ Insert data at 1/sec             300 entries
             ├─ Replicate to other nodes         <1s lag
             └─ Generator completes              ✓ Done

405s    6     Validate Final Entry Count
             ├─ Query node1                       ~300 entries
             ├─ Query node2                       ~300 entries
             └─ Query node3                       ~300 entries
                                                  ✓ +300 entries

410s    7     Promote node1 to PRIMARY
             ├─ POST /api/promote/node1           → Sent
             ├─ Auto-demote all nodes             ~ 15s
             ├─ Promote node1                     ~ 10s
             ├─ Reconfigure standbys              ~ 15s
             └─ Verify status                     ✓ node1=PRIMARY

450s    8     Validate Data Replication
             ├─ Query node1                       ~300 entries
             ├─ Query node2                       ~300 entries
             ├─ Query node3                       ~300 entries
             ├─ Check consistency                 ✓ All match
             └─ Verify replication lag            <1s ✓
                                                  ✓ PASSED

435s        TEST COMPLETE                         ✅ SUCCESS
```

---

## Data Flow During Test

```
PHASE 1: INITIALIZATION (t=0-100s)
═════════════════════════════════

Step 2: Demote All                Step 2: Promote node2
┌─────────────────┐              ┌──────────────────┐
│  node1          │              │  node1           │
│  STANDBY signal │◄─────────────┤  standby.signal  │
└─────────────────┘              └──────────────────┘
       ↓                                ↓
    STANDBY                          STANDBY
       
┌─────────────────┐              ┌──────────────────┐
│  node2          │              │  node2           │
│  STANDBY signal │◄─────────────┤  Remove signal   │
└─────────────────┘              │  pg_ctl promote  │
       ↓                                ↓
    STANDBY                          PRIMARY ✓
       
┌─────────────────┐              ┌──────────────────┐
│  node3          │              │  node3           │
│  STANDBY signal │◄─────────────┤  standby.signal  │
└─────────────────┘              └──────────────────┘
       ↓                                ↓
    STANDBY                          STANDBY


PHASE 2: DATA GENERATION (t=105-405s)
═════════════════════════════════════

┌──────────────────────────────────────────────┐
│ Test Data Generator                          │
│ ├─ INSERT INTO messages VALUES (...)        │
│ ├─ INSERT INTO messages VALUES (...)        │
│ └─ [repeat ~300 times over 5 minutes]       │
└──────────────────────────────────────────────┘
              ↓ (Write to Primary)
         ┌────────────┐
         │  node2     │
         │  PRIMARY   │
         │ (Write WAL)│
         └────────────┘
              │
              │ (Replication Stream)
              ├─────────────────────┬───────────────────┐
              ↓                     ↓                   ↓
         ┌────────────┐        ┌────────────┐   ┌────────────┐
         │  node1     │        │  node3     │   │  replica-1 │
         │  STANDBY   │        │  STANDBY   │   │  STANDBY   │
         │ (Replay)   │        │ (Replay)   │   │ (Replay)   │
         └────────────┘        └────────────┘   └────────────┘
         Data replicated to all nodes within 1 second


PHASE 3: FAILOVER (t=410-450s)
══════════════════════════════

Step 7: Demote node2, Promote node1

Before:                          After:
┌──────────────┐                ┌──────────────┐
│  node1       │                │  node1       │
│  STANDBY     │◄───────────────┤  PRIMARY ✓   │
└──────────────┘                └──────────────┘

┌──────────────┐                ┌──────────────┐
│  node2       │                │  node2       │
│  PRIMARY ✓   │────────────────►│  STANDBY     │
└──────────────┘                └──────────────┘

┌──────────────┐                ┌──────────────┐
│  node3       │                │  node3       │
│  STANDBY     │                │  STANDBY     │
└──────────────┘                └──────────────┘

Data persists on all nodes, primary changes
```

---

## State Transition Diagram

```
                    INITIAL STATE
                    ──────────────
                  All STANDBY nodes
                  No primary exists
                        │
                        │ Step 2: Promote node2
                        ↓
          ┌─────────────────────────────┐
          │  node1: STANDBY             │
          │  node2: PRIMARY ◆           │
          │  node3: STANDBY             │
          │  Data: Available (0 entries)│
          └─────────────────────────────┘
                        │
                        │ Step 3-4: Init DB
                        │           Check count
                        ↓
          ┌─────────────────────────────┐
          │  node1: STANDBY             │
          │  node2: PRIMARY ◆           │
          │  node3: STANDBY             │
          │  Data: Ready (0 entries)    │
          └─────────────────────────────┘
                        │
                        │ Step 5: Generate data
                        │         (5 minutes)
                        ↓
          ┌─────────────────────────────┐
          │  node1: STANDBY             │
          │  node2: PRIMARY ◆           │
          │  node3: STANDBY             │
          │  Data: Growing (~300 entries)
          │        Replicating...       │
          └─────────────────────────────┘
                        │
                        │ Step 6: Count entries
                        │ (~300 entries on all)
                        ↓
          ┌─────────────────────────────┐
          │  node1: STANDBY             │
          │  node2: PRIMARY ◆           │
          │  node3: STANDBY             │
          │  Data: Stable (~300 entries)│
          │        Replicated           │
          └─────────────────────────────┘
                        │
                        │ Step 7: Promote node1
                        │         (Auto-demote node2)
                        ↓
          ┌─────────────────────────────┐
          │  node1: PRIMARY ◆           │
          │  node2: STANDBY             │
          │  node3: STANDBY             │
          │  Data: Preserved (~300 ent.)│
          │        Still replicating    │
          └─────────────────────────────┘
                        │
                        │ Step 8: Validate
                        │ All nodes same count
                        ↓
                    ✅ SUCCESS
                All data consistent
                Replication verified
```

---

## Container Dependency & Boot Order

```
1. PostgreSQL Nodes (Parallel Start)
   ├─ postgres-node1 (5432) ──┐
   ├─ postgres-node2 (5435) ──├─→ Ready after ~10s
   ├─ postgres-node3 (5436) ──┤   (PostgreSQL init)
   ├─ postgres-replica-1 (5433)
   └─ postgres-replica-2 (5434)
          ↓ (All waiting for replication)

2. Management Services
   ├─ operationManagement (5001) ──→ Ready after nodes running
   └─ postgres-webserver (5000) ────→ Ready after nodes running
          ↓

3. Test Services (On Demand)
   ├─ db-init (--profile init)
   │  └─ Runs after nodes ready
   │     Creates schema & initial data
   │                ↓
   └─ test-data-generator-node2 (--profile test)
      └─ Runs after init
         Generates 5-minute data stream

Total bootstrap time: ~30-60 seconds
```

---

## Success Criteria Matrix

```
✓ = PASS  ✗ = FAIL  ~ = WARNING

CONTAINER HEALTH
┌───────────────────────────┬────┐
│ postgres-node1: UP        │ ✓  │
│ postgres-node2: UP        │ ✓  │
│ postgres-node3: UP        │ ✓  │
│ operationManagement: UP   │ ✓  │
│ postgres-webserver: UP    │ ✓  │
└───────────────────────────┴────┘

PROMOTION STEP 2
┌───────────────────────────┬────┐
│ node2 is_primary: true    │ ✓  │
│ node1 is_primary: false   │ ✓  │
│ node3 is_primary: false   │ ✓  │
└───────────────────────────┴────┘

DATA GENERATION
┌───────────────────────────┬────┐
│ Initial count: 0          │ ✓  │
│ Final count: ~300         │ ✓  │
│ Count growth: >250        │ ✓  │
└───────────────────────────┴────┘

DATA CONSISTENCY
┌───────────────────────────┬────┐
│ node1 count = 300         │ ✓  │
│ node2 count = 300         │ ✓  │
│ node3 count = 300         │ ✓  │
│ All counts equal          │ ✓  │
│ Replication lag: <1s      │ ✓  │
└───────────────────────────┴────┘

PROMOTION STEP 7
┌───────────────────────────┬────┐
│ node1 is_primary: true    │ ✓  │
│ node2 is_primary: false   │ ✓  │
│ node3 is_primary: false   │ ✓  │
└───────────────────────────┴────┘

FINAL STATE
┌───────────────────────────┬────┐
│ Data persisted            │ ✓  │
│ All nodes healthy         │ ✓  │
│ Replication working       │ ✓  │
│ Primary = node1           │ ✓  │
└───────────────────────────┴────┘

═══════════════════════════════════
         ✅ ALL TESTS PASS
═══════════════════════════════════
```

---

## Network Topology

```
┌──────────────────────────────────────────────────────────────┐
│                  Docker Bridge Network                       │
│              (172.18.0.0/16 - app-network)                   │
│                                                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐          │
│  │172.18.0.2   │  │172.18.0.3   │  │172.18.0.6   │          │
│  │postgres-    │  │postgres-    │  │postgres-    │          │
│  │node1:5432   │  │node2:5435   │  │node3:5436   │          │
│  └─────────────┘  └─────────────┘  └─────────────┘          │
│         ↑                ↑                  ↑                │
│         └────────────────┼──────────────────┘                │
│              Replication Network                            │
│                                                               │
│  ┌─────────────┐  ┌─────────────┐                           │
│  │172.18.0.4   │  │172.18.0.5   │                           │
│  │postgres-    │  │postgres-    │                           │
│  │replica-1    │  │replica-2    │                           │
│  └─────────────┘  └─────────────┘                           │
│         ↑                ↑                                    │
│         └────────────────┘                                   │
│              Replication Network                            │
│                                                               │
│  ┌─────────────────────────────────────────────┐            │
│  │172.18.0.7                                    │            │
│  │operationManagement API (Port 5001)          │            │
│  └─────────────────────────────────────────────┘            │
│                                                               │
│  ┌─────────────────────────────────────────────┐            │
│  │172.18.0.8                                    │            │
│  │postgres-webserver (Port 5000)               │            │
│  └─────────────────────────────────────────────┘            │
│                                                               │
└──────────────────────────────────────────────────────────────┘
       ↑
       │
       │ Port Mapping
       │
   ┌───┴────────────────────────────────────────────────────┐
   │           HOST (Windows)                               │
   │                                                         │
   │  localhost:5432 ──→ postgres-node1                     │
   │  localhost:5435 ──→ postgres-node2                     │
   │  localhost:5436 ──→ postgres-node3                     │
   │  localhost:5433 ──→ postgres-replica-1                │
   │  localhost:5434 ──→ postgres-replica-2                │
   │  localhost:5001 ──→ operationManagement                │
   │  localhost:5000 ──→ postgres-webserver                 │
   │                                                         │
   └──────────────────────────────────────────────────────────┘
```

---

**Diagram Generated:** January 16, 2026  
**Test Duration:** ~7 minutes  
**Expected Success Rate:** 95-100%
