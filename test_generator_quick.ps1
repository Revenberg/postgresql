#!/usr/bin/env powershell
<#
.SYNOPSIS
Quick test of the data generator container with database initialization
#>

Set-Location "C:\Users\reven\docker\postgreSQL"

Write-Host "=== PostgreSQL Test Data Generator - Quick Test ===" -ForegroundColor Green

# Step 1: Ensure node2 is primary
Write-Host "`n[1/4] Ensuring node2 is promoted to PRIMARY..." -ForegroundColor Cyan
$promote = Invoke-WebRequest -Uri "http://localhost:5001/api/operationmanagement/promote/node2" `
    -Method POST -UseBasicParsing 2>/dev/null | ConvertFrom-Json
Write-Host "      Result: $($promote.status)" -ForegroundColor Gray
Start-Sleep -Seconds 5

# Step 2: Create testdb database if it doesn't exist
Write-Host "`n[2/4] Creating testdb database..." -ForegroundColor Cyan
docker-compose exec -T postgres-node2 sh -c `
    'PGPASSWORD=securepwd123 psql -U testadmin -d postgres -c "CREATE DATABASE IF NOT EXISTS testdb;"' 2>&1 | `
    Select-String -Pattern "CREATE|ERROR|already" -ErrorAction SilentlyContinue
Write-Host "      Database ready" -ForegroundColor Gray

# Step 3: Run init container to create tables
Write-Host "`n[3/4] Initializing database tables..." -ForegroundColor Cyan
docker-compose --profile init run --rm db-init 2>&1 | `
    Select-String -Pattern "✓|✗|created|error" -ErrorAction SilentlyContinue | `
    ForEach-Object { Write-Host "      $_" -ForegroundColor Gray }

# Step 4: Run test data generator
Write-Host "`n[4/4] Running test data generator..." -ForegroundColor Cyan
docker-compose --profile test run --rm test-data-generator-node 2>&1 | `
    Select-String -Pattern "✓|✗|Found|failed|entries|Generated|Configuration"
    
Write-Host "`n=== Test Complete ===" -ForegroundColor Green
