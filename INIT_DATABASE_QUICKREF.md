# Init Database Container - Quick Reference

## What Was Changed

The database initialization container now **automatically detects the primary node** via API instead of connecting to a hardcoded node.

## 3 Files Updated

```
✅ init-database.sh        → Added API integration & primary detection
✅ Dockerfile.init         → Added curl & jq dependencies  
✅ docker-compose.yml      → Updated db-init service config
```

## New Behavior

### Before
```bash
# Hardcoded to node1
docker-compose --profile init run --rm db-init
# Always connects to postgres-node1:5432
```

### After
```bash
# Automatically finds primary node
docker-compose --profile init run --rm db-init
# Queries API → finds primary (e.g., node2)
# Connects to postgres-node2:5435
```

## How It Works

```
1. db-init container starts
   ↓
2. Waits for operationManagement API (port 5001)
   ↓
3. Calls GET /api/operationmanagement/status
   ↓
4. Parses JSON to find node with is_primary=true
   ↓
5. Maps node name to port (node2 → 5435)
   ↓
6. Connects to postgres-node2:5435
   ↓
7. Executes init.sql on primary
   ↓
8. Reports success and exits
```

## Key Changes

### init-database.sh
**Added:**
- `get_primary_node()` function - queries API for primary
- `get_node_port()` function - maps node→port
- curl installation fallback
- 30-second retry loop for API availability

**Removed:**
- Hardcoded DB_HOST (was: postgres-node1)
- Hardcoded DB_PORT (was: 5432)

### Dockerfile.init
**Added:**
- `curl` - HTTP client for API calls
- `jq` - JSON parser (optional, for response parsing)

### docker-compose.yml (db-init)
**Added:**
```yaml
depends_on:
  - operationManagement    # API must be ready first
  - postgres-node1/2/3     # All nodes must exist
```

**Changed:**
```yaml
# OLD
environment:
  DB_HOST: postgres-node1
  DB_PORT: 5432

# NEW
environment:
  API_URL: http://operationManagement:5001
```

## Testing

### Test 1: Init on Current Primary
```bash
docker-compose --profile init run --rm db-init
# ✓ Finds primary and initializes
```

### Test 2: Init After Promotion
```bash
# Make node1 primary
curl -X POST http://localhost:5001/api/operationmanagement/promote/node1
sleep 40

# Re-init on new primary
docker-compose --profile init run --rm db-init
# ✓ Now initializes on node1 (5432) instead of node2 (5435)
```

## Integration with comprehensive_test.ps1

The comprehensive test script already calls:
```powershell
docker-compose --profile init run --rm db-init
```

This now automatically:
- Detects which node is primary
- Connects to the correct port
- Initializes database on primary

**No changes needed to comprehensive_test.ps1** ✓

## Logging

Check what the init container did:
```bash
docker-compose logs db-init
```

Example output:
```
[2026-01-16 12:30:45] PostgreSQL Database Initializer
[2026-01-16 12:30:45] API URL: http://operationManagement:5001
[2026-01-16 12:30:45] Database: testdb
[2026-01-16 12:30:45] Querying API for primary node...
[2026-01-16 12:30:45] ✓ Found primary node: node2
[2026-01-16 12:30:45] Connecting to primary: postgres-node2:5435
[2026-01-16 12:30:47] ✓ PostgreSQL is ready!
[2026-01-16 12:30:48] ✓ init.sql executed successfully
[2026-01-16 12:30:48] ✓ Database initialization completed successfully!
```

## Rollback (If Needed)

To restore hardcoded behavior:
```bash
git checkout init-database.sh docker-compose.yml Dockerfile.init
```

Or manually set DB_HOST/DB_PORT in docker-compose.yml.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "Failed to find primary node" | Check if operationManagement is running: `docker-compose ps operationManagement` |
| "Connection refused" | Wait for all nodes to start: `sleep 30` |
| "init.sql not found" | Verify `init.sql` exists in current directory |
| "Cannot execute init.sql" | Check file permissions: `ls -la init.sql` |

## Benefits Summary

✅ No hardcoded node names  
✅ Works with any node as primary  
✅ Automatic failover support  
✅ API-driven configuration  
✅ Scalable architecture  
✅ Backward compatible  

---

**Status:** ✅ Ready to use  
**Files Updated:** 3  
**Breaking Changes:** None  
**Rollback:** Simple (git checkout)
