# PostgreSQL Cluster Comprehensive Test - Restart Instructions

## Overview
This document provides step-by-step instructions for running the comprehensive PostgreSQL cluster test (`comprehensive_test.ps1`).

## Execute
cd "C:\Users\reven\docker\postgreSQL"
docker-compose down -v
docker-compose up -d
Start-Sleep -Seconds 30
Write-Host "Promoting node2 to primary..." -ForegroundColor Cyan
Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/node2" -Method POST -UseBasicParsing -TimeoutSec 180 -ErrorAction SilentlyContinue | Out-Null
Start-Sleep -Seconds 20
Write-Host "Starting comprehensive test..." -ForegroundColor Green
powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1


## Prerequisites
- Docker and Docker Compose installed
- PowerShell 7+ (or Windows PowerShell 5.1)
- PostgreSQL client tools (`psql`, `pg_isready`) installed on host
- Administrator privileges (may be needed for Docker operations)

## Pre-Test Checklist

Before starting the test, ensure:

```bash
# 1. Verify all containers are stopped/cleaned
cd C:\Users\reven\docker\postgreSQL
docker-compose down

# 2. Clean volumes (CAUTION: This deletes all data!)
docker-compose down -v

# 3. Rebuild containers from latest Dockerfiles
docker-compose build --no-cache

# 4. Verify Dockerfile.init exists
ls -la Dockerfile.init

# 5. Verify all required services in docker-compose.yml
docker-compose config | grep -E "postgres|testgen|operationManagement"
```

## Running the Test

### Method 1: Using PowerShell Script (Recommended)

```powershell
# Navigate to PostgreSQL directory
cd "C:\Users\reven\docker\postgreSQL"

# Start Docker containers
docker-compose up -d

# Wait for services to be ready (30-60 seconds)
Start-Sleep -Seconds 30

# Run comprehensive test
powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
```

### Method 2: Manual Step-by-Step

```powershell
# 1. Start all containers
docker-compose up -d

# 2. Check container health
docker-compose ps

# 3. Set node2 as primary
$response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/node2" `
    -Method POST -UseBasicParsing -TimeoutSec 180
Start-Sleep -Seconds 40

# 4. Check current primary
$status = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status" `
    -UseBasicParsing | ConvertFrom-Json
Write-Host "Current primary: node1=$($status.nodes.node1.is_primary), node2=$($status.nodes.node2.is_primary), node3=$($status.nodes.node3.is_primary)"

# 5. Initialize database
docker-compose --profile init run --rm db-init

# 6. Check entry count on node2 (primary)
$env:PGPASSWORD = "securepwd123"
psql -h localhost -p 5435 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

# 7. Start test data generator (5 minutes)
docker-compose --profile test run --rm test-data-generator-node2

# 8. Check entry count again
psql -h localhost -p 5435 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

# 9. Promote node1 to primary
$response = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/node1" `
    -Method POST -UseBasicParsing -TimeoutSec 180
Start-Sleep -Seconds 40

# 10. Verify node1 is now primary
$status = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status" `
    -UseBasicParsing | ConvertFrom-Json
Write-Host "Current primary: node1=$($status.nodes.node1.is_primary), node2=$($status.nodes.node2.is_primary), node3=$($status.nodes.node3.is_primary)"

# 11. Check data is replicated to node1
psql -h localhost -p 5432 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"
```

## Expected Test Timeline

| Phase | Duration | Action |
|-------|----------|--------|
| 1. Container startup | 30-60s | Containers start and become healthy |
| 2. Set node2 primary | 40s | Promotion request sent, operation completes |
| 3. Database init | 10-20s | Schema and initial data created |
| 4. Entry count check | 5s | Query node2 for entry count |
| 5. Data generation | 300s (5min) | Test generator inserts random data |
| 6. Verify count | 5s | Query final entry count |
| 7. Promote node1 | 40s | Failover to node1 (auto-demote all first) |
| 8. Verify replication | 5s | Check data consistency across nodes |
| **Total** | **~435s (7 min)** | Complete test sequence |

## Test Success Criteria

✓ All containers are running and healthy  
✓ Node2 becomes PRIMARY after step 2  
✓ Database initializes without errors  
✓ Entry count increases during test data generation (typically 300+ entries)  
✓ All nodes show same entry count (data is replicated)  
✓ Node1 becomes PRIMARY after step 7  
✓ Node2 and Node3 become STANDBY  
✓ Data count remains consistent across all nodes  

## Troubleshooting

### Issue: "Connection refused" when querying database
```powershell
# Verify containers are running
docker-compose ps

# Wait longer for containers to be ready
Start-Sleep -Seconds 60
docker-compose ps
```

### Issue: "psql: command not found"
```powershell
# Install PostgreSQL client tools
# Option 1: Windows Package Manager
winget install PostgreSQL.PostgreSQL.16

# Option 2: Chocolatey
choco install postgresql

# Option 3: Manual download
# https://www.postgresql.org/download/windows/
```

### Issue: Init container fails
```bash
# Check init container logs
docker-compose --profile init logs db-init

# Verify init.sql and init-database.sh exist
ls -la init.sql init-database.sh

# Manually check database
docker-compose exec postgres-node2 psql -U testadmin -d postgres -c "\l"
```

### Issue: Test data generator not inserting data
```powershell
# Check generator logs
docker-compose --profile test logs test-data-generator-node2

# Manually verify table exists
$env:PGPASSWORD = "securepwd123"
psql -h localhost -p 5435 -U testadmin -d testdb -c "\dt"
```

### Issue: Promotion times out or fails
```powershell
# Check operationManagement logs
docker-compose logs operationManagement --tail=100

# Check if primary node exists
$status = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/status" -UseBasicParsing
$status.Content | ConvertFrom-Json | ConvertTo-Json

# Restart operationManagement service
docker-compose restart operationManagement
docker-compose up -d postgres-node1 postgres-node2 postgres-node3
```

### Issue: Data inconsistency between nodes
```powershell
# Query entry count on each node
$env:PGPASSWORD = "securepwd123"

Write-Host "Node1 (5432):"
psql -h localhost -p 5432 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

Write-Host "Node2 (5435):"
psql -h localhost -p 5435 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

Write-Host "Node3 (5436):"
psql -h localhost -p 5436 -U testadmin -d testdb -c "SELECT COUNT(*) FROM messages;"

# Check replication lag
docker-compose exec postgres-node1 psql -U testadmin -d testdb -c "SELECT client_addr, state, replay_lag FROM pg_stat_replication;"
```

## Clean Up After Test

```powershell
# Option 1: Keep containers for inspection
docker-compose ps
docker-compose logs operationManagement
docker-compose logs postgres-node1

# Option 2: Stop containers but keep volumes
docker-compose stop

# Option 3: Full cleanup (deletes all data)
docker-compose down -v
```

## Running Tests Repeatedly

To run the test multiple times in sequence:

```powershell
# Run test 5 times with cleanup between runs
for ($i = 1; $i -le 5; $i++) {
    Write-Host "`n=== Test Run $i ===" -ForegroundColor Green
    
    # Full cleanup
    docker-compose down -v
    
    # Start fresh
    docker-compose up -d
    Start-Sleep -Seconds 30
    
    # Run test
    powershell -ExecutionPolicy Bypass -File comprehensive_test.ps1
    
    # Wait before next iteration
    Start-Sleep -Seconds 60
}
```

## Integration with CI/CD

To integrate this test into CI/CD pipeline:

```yaml
# Example GitHub Actions workflow
name: PostgreSQL Cluster Test
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Start containers
        run: docker-compose up -d
      - name: Run test
        run: pwsh -ExecutionPolicy Bypass -File comprehensive_test.ps1
      - name: Check results
        if: always()
        run: docker-compose logs
```

## Advanced Debugging

### Enable verbose logging in containers
```bash
docker-compose exec postgres-node1 sed -i "s/log_statement = 'none'/log_statement = 'all'/" /var/lib/postgresql/data/postgresql.conf
docker-compose restart postgres-node1
```

### Monitor replication in real-time
```bash
watch -n 1 'docker-compose exec -T postgres-node1 psql -U testadmin -d testdb -c "SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"'
```

### Capture detailed metrics
```powershell
# Create metrics capture
$outputFile = "test_metrics_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
Start-Transcript -Path $outputFile
# Run test...
Stop-Transcript
```

## Support

For issues or questions:

1. Check logs: `docker-compose logs <service>`
2. Verify network: `docker network inspect postgresql_app-network`
3. Inspect volumes: `docker volume ls | grep postgre`
4. Check API health: `Invoke-WebRequest -Uri "http://localhost:5001/health"`

---

**Last Updated:** January 16, 2026  
**PostgreSQL Version:** 14.2  
**Test Duration:** ~7 minutes  
**Success Rate Target:** 100%
