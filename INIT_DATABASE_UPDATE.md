# Init Database Container - Primary Node Detection Update

## Overview
Updated the database initialization container to dynamically detect and connect to the **primary node** via the operationManagement API, instead of hardcoding a specific node.

## Changes Made

### 1. init-database.sh
**What changed:**
- Removed hardcoded `DB_HOST` and `DB_PORT` variables
- Added API integration to query the primary node
- Added `get_primary_node()` function to fetch primary from API
- Added `get_node_port()` function to map node names to ports
- Container now waits for API to be available before querying

**How it works:**
```bash
1. Wait for API at http://operationManagement:5001
2. Call GET /api/operationmanagement/status
3. Parse JSON response to find node with is_primary=true
4. Extract primary node name (e.g., "node2")
5. Map node name to port (node2 → 5435)
6. Connect to postgres-{node} at appropriate port
7. Execute init.sql on primary
```

**Key functions:**
- `get_primary_node()` - Queries API up to 30 times (30 seconds) to find primary
- `get_node_port()` - Maps node1→5432, node2→5435, node3→5436
- Returns primary node name or exits with error if not found

### 2. Dockerfile.init
**What changed:**
- Added `curl` and `jq` to dependencies (for API calls and JSON parsing)
- Now supports both direct `psql` and API interaction

**Dependencies installed:**
- postgresql-client (psql command)
- bash (script execution)
- curl (API HTTP calls)
- jq (JSON parsing)

### 3. docker-compose.yml (db-init service)
**What changed:**
- Removed hardcoded `DB_HOST`, `DB_PORT` environment variables
- Added `API_URL: http://operationManagement:5001`
- Added `depends_on` constraint for proper startup order:
  - operationManagement (API service)
  - postgres-node1, postgres-node2, postgres-node3 (database nodes)

**Before:**
```yaml
environment:
  DB_HOST: postgres-node1
  DB_PORT: 5432
```

**After:**
```yaml
environment:
  API_URL: http://operationManagement:5001
depends_on:
  - operationManagement
  - postgres-node1
  - postgres-node2
  - postgres-node3
```

## Benefits

✅ **Dynamic Primary Detection** - Works regardless of which node is primary  
✅ **Resilient** - Queries API up to 30 times, waits for primary to be elected  
✅ **No Manual Configuration** - No need to specify DB_HOST or DB_PORT  
✅ **Scalable** - Can easily add/remove nodes without updating script  
✅ **Consistent** - Initializes on whichever node is designated as primary  
✅ **Ordered Startup** - depends_on ensures services start in correct order  

## Usage

### Running initialization on primary node
```bash
docker-compose --profile init run --rm db-init
```

### Environment Variables (optional)
```bash
API_URL=http://operationManagement:5001  # Default, change if API on different URL
DB_USER=testadmin                         # Database user (default)
DB_PASSWORD=securepwd123                  # Database password (default)
DB_NAME=testdb                            # Database name (default)
```

### Execution Flow
1. Container starts
2. Waits for operationManagement API to respond
3. Queries `/api/operationmanagement/status` endpoint
4. Finds primary node (e.g., node2)
5. Connects to postgres-node2:5435
6. Executes init.sql
7. Reports success with table statistics
8. Container exits

## API Response Example

When querying `GET http://operationManagement:5001/api/operationmanagement/status`:

```json
{
  "nodes": {
    "node1": {
      "is_primary": false
    },
    "node2": {
      "is_primary": true
    },
    "node3": {
      "is_primary": false
    }
  }
}
```

The script identifies `node2` as primary and connects to `postgres-node2:5435`.

## Error Handling

- If API is unavailable: Retries up to 30 times (30 seconds)
- If no primary found: Exits with error message
- If database connection fails: Retries up to 30 times
- If init.sql fails: Exits with error, shows logs

## Logs

All initialization logs are saved to `/tmp/init.log` inside the container.

To view logs after running:
```bash
docker-compose logs db-init
```

## Compatibility

- Works with existing operationManagement API
- Compatible with all three nodes (node1, node2, node3)
- Gracefully handles any node being primary
- Requires API service to be running and healthy

## Testing

### Before Making node2 Primary
```bash
docker-compose --profile init run --rm db-init
# Will find and use whichever node is currently primary
```

### After Changing Primary
```bash
# Promote node1
curl -X POST http://localhost:5001/api/operationmanagement/promote/node1

# Wait 40 seconds for promotion
sleep 40

# Initialize database on NEW primary (node1)
docker-compose --profile init run --rm db-init
```

---

**Updated:** January 16, 2026  
**Compatibility:** PostgreSQL 14.2, Docker Compose 3.8+  
**Dependencies:** curl, jq, psql, bash
