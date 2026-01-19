#!/usr/bin/env powershell
# Test Node Type Configuration

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "PostgreSQL Cluster Node Type Verification"
Write-Host "======================================================================" -ForegroundColor Cyan

$nodes = @(
    @{name="postgres-node1"; type="BACKUP"; shouldHaveSignal=$false},
    @{name="postgres-node2"; type="BACKUP"; shouldHaveSignal=$false},
    @{name="postgres-node3"; type="BACKUP"; shouldHaveSignal=$false},
    @{name="postgres-replica-1"; type="REPLICA"; shouldHaveSignal=$true},
    @{name="postgres-replica-2"; type="REPLICA"; shouldHaveSignal=$true}
)

$passCount = 0
$failCount = 0

foreach ($node in $nodes) {
    Write-Host "`n[TEST] $($node.name) [$($node.type)]"
    
    # Check if standby.signal exists
    $signal_exists = docker exec $node.name test -f /var/lib/postgresql/data/standby.signal 2>&1
    $hasSignal = $LASTEXITCODE -eq 0
    
    # Get node logs to verify startup message
    $logs = docker logs $node.name 2>&1 | Select-String "Node Type:|Status:" | Select-Object -Last 2
    
    Write-Host "  Node Type Message: $($logs[0])"
    Write-Host "  Status Message: $($logs[1])"
    
    # Verify correct state
    if ($node.shouldHaveSignal -eq $hasSignal) {
        if ($node.shouldHaveSignal) {
            Write-Host "  [PASS] standby.signal EXISTS - locked as replica" -ForegroundColor Green
        } else {
            Write-Host "  [PASS] standby.signal NOT FOUND - can be promoted" -ForegroundColor Green
        }
        $passCount++
    } else {
        if ($node.shouldHaveSignal) {
            Write-Host "  [FAIL] standby.signal should exist but does not" -ForegroundColor Red
        } else {
            Write-Host "  [FAIL] standby.signal should not exist but does" -ForegroundColor Red
        }
        $failCount++
    }
}

Write-Host "`n======================================================================" -ForegroundColor Cyan
Write-Host "Test Results: $passCount PASS, $failCount FAIL" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan

if ($failCount -eq 0) {
    Write-Host "`n[SUCCESS] All tests passed! Node types are configured correctly." -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n[FAILED] Some tests failed!" -ForegroundColor Red
    exit 1
}
