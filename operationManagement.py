#!/usr/bin/env python3
"""
PostgreSQL operationmanagement Service
Provides API endpoints to perform operationmanagement operations between nodes
"""

from flask import Flask, jsonify, request
from flask_cors import CORS
import subprocess
import os
import time
import psycopg2
from psycopg2.extras import RealDictCursor
import sys

app = Flask(__name__)

# Enable CORS for all routes
CORS(app, resources={
    r"/api/*": {
        "origins": "*",
        "methods": ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
        "allow_headers": ["Content-Type"]
    }
})

# Global request timing
_request_start_time = None

# Configure logging for all requests
@app.before_request
def log_request():
    """Log all incoming requests with timing"""
    global _request_start_time
    _request_start_time = time.time()
    
    print("\n" + "="*80, file=sys.stderr)
    print(f"[REQUEST] [{time.strftime('%Y-%m-%d %H:%M:%S')}] {request.method} {request.path}", file=sys.stderr)
    print(f"[REQUEST] Client IP: {request.remote_addr}", file=sys.stderr)
    print(f"[REQUEST] User-Agent: {request.headers.get('User-Agent', 'N/A')}", file=sys.stderr)
    
    # Log headers
    print(f"[REQUEST] Headers:", file=sys.stderr)
    for header, value in request.headers:
        if header.lower() not in ['authorization', 'password', 'cookie']:
            print(f"[REQUEST]   {header}: {value}", file=sys.stderr)
    
    # Log request body for POST/PUT requests
    if request.method in ['POST', 'PUT', 'PATCH']:
        try:
            if request.is_json:
                print(f"[REQUEST] Body (JSON): {request.get_json()}", file=sys.stderr)
            elif request.data:
                print(f"[REQUEST] Body (Raw): {request.data}", file=sys.stderr)
        except Exception as e:
            print(f"[REQUEST] Body parsing error: {e}", file=sys.stderr)
    
    sys.stderr.flush()

@app.after_request
def log_response(response):
    """Log response details with elapsed time"""
    global _request_start_time
    
    elapsed_time = 0
    if _request_start_time:
        elapsed_time = time.time() - _request_start_time
    
    print(f"[RESPONSE] Status: {response.status_code} | Elapsed: {elapsed_time:.3f}s", file=sys.stderr)
    print(f"[RESPONSE] Content-Type: {response.content_type}", file=sys.stderr)
    
    # Log response body for successful responses
    try:
        if response.is_json and response.status_code < 400:
            import json
            data = json.loads(response.get_data(as_text=True))
            print(f"[RESPONSE] Body: {json.dumps(data, indent=2)}", file=sys.stderr)
    except Exception as e:
        print(f"[RESPONSE] Could not parse response body: {e}", file=sys.stderr)
    
    print("="*80 + "\n", file=sys.stderr)
    sys.stderr.flush()
    return response

# Node configuration
NODES = {
    'node1': {'container': 'postgres-node1', 'hostname': 'postgres-node1', 'ip_address': '172.18.0.2', 'port': 5432, 'type': 'backup', 'is_replica': False, 'db_cluster': None},
    'node2': {'container': 'postgres-node2', 'hostname': 'postgres-node2', 'ip_address': '172.18.0.3', 'port': 5435, 'type': 'backup', 'is_replica': False, 'db_cluster': None},
    'node3': {'container': 'postgres-node3', 'hostname': 'postgres-node3', 'ip_address': '172.18.0.6', 'port': 5436, 'type': 'backup', 'is_replica': False, 'db_cluster': None},
    'replica-1': {'container': 'postgres-replica-1', 'hostname': 'postgres-replica-1', 'ip_address': '172.18.0.4', 'port': 5433, 'type': 'replica', 'is_replica': True, 'db_cluster': None},
    'replica-2': {'container': 'postgres-replica-2', 'hostname': 'postgres-replica-2', 'ip_address': '172.18.0.5', 'port': 5434, 'type': 'replica', 'is_replica': True, 'db_cluster': None},
}

DB_CONFIG = {
    'user': 'testadmin',
    'password': 'securepwd123',
    'database': 'postgres'
}

# Database cluster configuration
DB_CLUSTERS = {}

def get_node_status(node_name):
    """Get the current status of a node"""
    print(f"\n[DEBUG] get_node_status({node_name}) START", file=sys.stderr)
    sys.stderr.flush()
    
    if node_name not in NODES:
        print(f"[ERROR] Invalid node name: {node_name}", file=sys.stderr)
        sys.stderr.flush()
        return {'status': 'error', 'message': 'Invalid node name'}
    
    node = NODES[node_name]
    container = node['container']
    print(f"[DEBUG] Container: {container}", file=sys.stderr)
    sys.stderr.flush()
    
    try:
        # Check if container is running
        print(f"[DEBUG] Checking if container is running...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'inspect', '-f', '{{.State.Running}}', container],
            capture_output=True,
            text=True,
            timeout=5
        )
        

        print(f"[DEBUG] Docker inspect result: returncode={result.returncode}, stdout={result.stdout.strip()}", file=sys.stderr)
        sys.stderr.flush()
        
        if result.returncode != 0 or 'false' in result.stdout:
            print(f"[DEBUG] Container is not running", file=sys.stderr)
            sys.stderr.flush()
            return {'status': 'disconnected', 'is_primary': False, 'container': container}
        
        print(f"[DEBUG] Container is running, checking if primary...", file=sys.stderr)
        sys.stderr.flush()
        
        # Connect to node to check role
        config = DB_CONFIG.copy()
        config['host'] = container
        config['port'] = 5432
        
        try:
            print(f"[DEBUG] Connecting to {container}:5432...", file=sys.stderr)
            sys.stderr.flush()
            conn = psycopg2.connect(**config, connect_timeout=3)
            print(f"[DEBUG] Connected successfully", file=sys.stderr)
            sys.stderr.flush()
            
            cur = conn.cursor(cursor_factory=RealDictCursor)
            cur.execute("SELECT pg_is_in_recovery();")
            result = cur.fetchone()
            in_recovery = result['pg_is_in_recovery'] if result else True
            cur.close()
            conn.close()
            
            is_primary = not in_recovery
            print(f"[DEBUG] in_recovery={in_recovery}, is_primary={is_primary}", file=sys.stderr)
            sys.stderr.flush()
            
            return {
                'status': 'connected',
                'is_primary': is_primary,
                'container': container
            }
        except psycopg2.Error as e:
            print(f"[ERROR] Connection failed: {e}", file=sys.stderr)
            sys.stderr.flush()
            return {'status': 'disconnected', 'is_primary': False, 'container': container, 'error': str(e)}
    
    except Exception as e:
        print(f"[ERROR] Unexpected error: {e}", file=sys.stderr)
        sys.stderr.flush()
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        return {'status': 'error', 'is_primary': False, 'container': container, 'error': str(e)}

def get_current_primary():
    """Determine which node is currently primary"""
    print(f"\n[DEBUG] get_current_primary() START", file=sys.stderr)
    sys.stderr.flush()
    for node_name in NODES:
        print(f"[DEBUG] Checking {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        status = get_node_status(node_name)
        print(f"[DEBUG] {node_name} status: {status}", file=sys.stderr)
        sys.stderr.flush()
        if status.get('is_primary'):
            print(f"[DEBUG] PRIMARY FOUND: {node_name}", file=sys.stderr)
            sys.stderr.flush()
            return node_name
    print(f"[DEBUG] No primary found!", file=sys.stderr)
    sys.stderr.flush()
    return None

@app.route('/health', methods=['GET'])
def health():
    """Health check endpoint"""
    return jsonify({'status': 'healthy', 'service': 'operationmanagement_service'}), 200

@app.route('/api/operationmanagement/status', methods=['GET'])
def operationmanagement_status():
    """Get current cluster status"""
    print(f"\n[API] GET /api/operationmanagement/status", file=sys.stderr)
    sys.stderr.flush()
    status = {}
    for node_name in NODES:
        print(f"[API] Getting status for {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        status[node_name] = get_node_status(node_name)
    
    result = {
        'nodes': status,
        'timestamp': time.time()
    }
    print(f"[API] Returning: {result}", file=sys.stderr)
    sys.stderr.flush()
    return jsonify(result), 200

@app.route('/api/operationmanagement/status/<node_name>', methods=['GET'])
def get_status(node_name):
    """Get status of a specific node"""
    print(f"\n[API] GET /api/operationmanagement/status/{node_name}", file=sys.stderr)
    sys.stderr.flush()
    
    if node_name not in NODES:
        print(f"[ERROR] Invalid node name: {node_name}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Invalid node name'}), 400
    
    status = get_node_status(node_name)
    
    result = {
        'node': node_name,
        'status': status,
        'timestamp': time.time()
    }
    print(f"[API] Returning: {result}", file=sys.stderr)
    sys.stderr.flush()
    return jsonify(result), 200

@app.route('/api/operationmanagement/promote/<node_name>', methods=['POST'])
def promote_node(node_name):
    """Promote a node to primary"""
    print(f"\n[API] POST /api/operationmanagement/promote/{node_name}", file=sys.stderr)
    sys.stderr.flush()
    if node_name not in NODES:
        print(f"[ERROR] Invalid node name: {node_name}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Invalid node name'}), 400
    
    # Prevent replicas from being promoted to primary
    if NODES[node_name].get('is_replica', False):
        print(f"[ERROR] Cannot promote replica node {node_name} to primary", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': f'Replicas cannot be promoted to primary (node {node_name} is a replica)'}), 400
    
    try:
        # Check if there's already a primary and demote it first
        print(f"[API] Checking for existing primary nodes...", file=sys.stderr)
        sys.stderr.flush()
        current_primary = get_current_primary()
        
        if current_primary:
            print(f"[API] Found existing primary: {current_primary}, demoting it first...", file=sys.stderr)
            sys.stderr.flush()
            
            primary_container = NODES[current_primary]['container']
            
            # Create standby.signal on the current primary
            print(f"[API] Creating standby.signal on {current_primary}...", file=sys.stderr)
            sys.stderr.flush()
            result = subprocess.run(
                ['docker', 'exec', primary_container, 'bash', '-c',
                 'touch /var/lib/postgresql/data/standby.signal'],
                capture_output=True,
                text=True,
                timeout=20
            )
            print(f"[API] standby.signal result: {result.returncode}", file=sys.stderr)
            sys.stderr.flush()
            
            time.sleep(1)
            
            # Restart the primary to demote it
            print(f"[API] Restarting {current_primary} to demote to standby...", file=sys.stderr)
            sys.stderr.flush()
            result = subprocess.run(
                ['docker', 'restart', primary_container],
                capture_output=True,
                text=True,
                timeout=60
            )
            print(f"[API] Restart result: {result.returncode}", file=sys.stderr)
            sys.stderr.flush()
            
            time.sleep(3)
            print(f"[API] Demotion of {current_primary} complete", file=sys.stderr)
            sys.stderr.flush()
        else:
            print(f"[API] No existing primary found - all nodes are standby", file=sys.stderr)
            sys.stderr.flush()
        
        container = NODES[node_name]['container']
        print(f"[API] Promoting {node_name} ({container}) to primary", file=sys.stderr)
        sys.stderr.flush()
        
        # First, resume WAL replay on the target node
        print(f"[API] Resuming WAL replay on {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c', 
             f'PGPASSWORD={DB_CONFIG["password"]} psql -U {DB_CONFIG["user"]} -d postgres -c "SELECT pg_wal_replay_resume();" 2>/dev/null'],
            capture_output=True,
            text=True,
            timeout=10
        )
        print(f"[API] WAL resume result: {result.returncode}", file=sys.stderr)
        sys.stderr.flush()
        
        time.sleep(2)
        
        # Promote using pg_ctl
        print(f"[API] Running pg_ctl promote on {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c',
             'su - postgres -c "/usr/lib/postgresql/18/bin/pg_ctl promote -D /var/lib/postgresql/data"'],
            capture_output=True,
            text=True,
            timeout=10
        )
        print(f"[API] pg_ctl promote result: {result.returncode}", file=sys.stderr)
        print(f"[API] stdout: {result.stdout}", file=sys.stderr)
        if result.stderr:
            print(f"[API] stderr: {result.stderr}", file=sys.stderr)
        sys.stderr.flush()
        
        time.sleep(3)
        
        # Verify promotion by checking if node is now primary
        print(f"[API] Verifying promotion...", file=sys.stderr)
        sys.stderr.flush()
        status = get_node_status(node_name)
        is_primary = status.get('is_primary', False)
        print(f"[API] Verification result - is_primary: {is_primary}", file=sys.stderr)
        sys.stderr.flush()
        
        # Check if node is replica (should never be primary)
        if NODES[node_name].get('is_replica', False):
            print(f"[ERROR] Replica node {node_name} became primary - this should not happen!", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'status': 'failed',
                'node': node_name,
                'message': f'ERROR: Replica node {node_name} became primary (safety violation)',
                'is_primary': True,
                'error': 'Replica node must never be primary'
            }), 500
        
        if is_primary:
            print(f"[API] Promotion successful for {node_name}", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'status': 'success',
                'node': node_name,
                'message': f'{node_name} promoted to primary',
                'is_primary': True
            }), 200
        else:
            print(f"[API] Promotion verification failed - node is not primary", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'status': 'failed',
                'node': node_name,
                'message': f'{node_name} promotion failed - not primary',
                'is_primary': False
            }), 500
        
    except subprocess.TimeoutExpired as e:
        print(f"[ERROR] Timeout during promotion: {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Timeout during promotion', 'status': 'timeout'}), 500
    except Exception as e:
        print(f"[ERROR] Exception during promotion: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e), 'status': 'error'}), 500
        container = NODES[node_name]['container']
        step_number = 1
        
        # Step 1: Demote all nodes first to ensure clean state
        print(f"\n[operationmanagement] Step {step_number}: Demoting all nodes to standby first", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        for node in NODES:
            node_container = NODES[node]['container']
            print(f"[operationmanagement] Step {step_number}: Adding standby.signal to {node} ({node_container})...", file=sys.stderr)
            sys.stderr.flush()
            
            result = subprocess.run(
                ['docker', 'exec', node_container, 'bash', '-c',
                 'touch /var/lib/postgresql/data/standby.signal'],
                capture_output=True,
                text=True,
                timeout=10
            )
            print(f"[operationmanagement] Step {step_number}: Standby signal result - returncode={result.returncode}", file=sys.stderr)
            if result.returncode != 0:
                print(f"[operationmanagement] Step {step_number}: stderr: {result.stderr}", file=sys.stderr)
            sys.stderr.flush()
            step_number += 1
        
        # Restart all nodes
        print(f"[operationmanagement] Step {step_number}: Restarting all nodes as standby...", file=sys.stderr)
        sys.stderr.flush()
        for node in NODES:
            node_container = NODES[node]['container']
            result = subprocess.run(['docker', 'restart', node_container], capture_output=True, text=True, timeout=10)
            print(f"[operationmanagement] Step {step_number}: {node} restart result - returncode={result.returncode}", file=sys.stderr)
            sys.stderr.flush()
        step_number += 1
        
        time.sleep(5)
        step_number += 1

        # Now promote the specified node
        print(f"[operationmanagement] Step {step_number}: Starting promotion of {node_name} ({container}) to primary", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        # Resume WAL replay first
        print(f"[operationmanagement] Step {step_number}: Resuming WAL replay on {container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c', 
             f'PGPASSWORD={DB_CONFIG["password"]} psql -U {DB_CONFIG["user"]} -d postgres -c "SELECT pg_wal_replay_resume();"'],
            capture_output=True,
            text=True,
            timeout=10
        )
        print(f"[operationmanagement] Step {step_number}: WAL resume result: returncode={result.returncode}", file=sys.stderr)
        if result.stderr:
            print(f"[operationmanagement] Step {step_number}: stderr: {result.stderr}", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        time.sleep(2)
        
        # Promote using pg_ctl (this will handle removing standby.signal)
        print(f"[operationmanagement] Step {step_number}: Running pg_ctl promote on {container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c',
             'su - postgres -c "/usr/lib/postgresql/18/bin/pg_ctl promote -D /var/lib/postgresql/data"'],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        print(f"[operationmanagement] Step {step_number}: pg_ctl promote result:", file=sys.stderr)
        print(f"[operationmanagement]   returncode={result.returncode}", file=sys.stderr)
        print(f"[operationmanagement]   stdout: {result.stdout if result.stdout else '(empty)'}", file=sys.stderr)
        print(f"[operationmanagement]   stderr: {result.stderr if result.stderr else '(empty)'}", file=sys.stderr)
        sys.stderr.flush()
        
        if result.returncode != 0:
            print(f"[ERROR] Step {step_number}: Promotion command failed with returncode {result.returncode}", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'error': 'Promotion command failed',
                'status': 'promotion_failed',
                'details': result.stderr
            }), 500
        
        step_number += 1
        
        # Wait for promotion to complete
        print(f"[operationmanagement] Step {step_number}: Waiting 5 seconds for promotion to stabilize...", file=sys.stderr)
        sys.stderr.flush()
        time.sleep(5)
        step_number += 1
        
        # Verify promotion
        print(f"[operationmanagement] Step {step_number}: Verifying promotion of {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        verify_status = get_node_status(node_name)
        print(f"[operationmanagement] Step {step_number}: Verification result: {verify_status}", file=sys.stderr)
        sys.stderr.flush()
        
        if not verify_status.get('is_primary'):
            print(f"[ERROR] Step {step_number}: Promotion verification failed - node is not primary", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'error': 'Promotion verification failed',
                'status': 'verification_failed'
            }), 500
        
        step_number += 1
        print(f"[operationmanagement] Step {step_number}: Promotion verification SUCCESSFUL - {node_name} is now primary", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        # Reconfigure other nodes as standby
        print(f"[operationmanagement] Step {step_number}: Reconfiguring remaining nodes as standby...", file=sys.stderr)
        sys.stderr.flush()
        for other_node in NODES:
            if other_node == node_name:
                continue
            print(f"[operationmanagement] Step {step_number}: Reconfiguring {other_node} as standby...", file=sys.stderr)
            sys.stderr.flush()
            reconfigure_standby(other_node, node_name)
        
        step_number += 1
        print(f"[operationmanagement] Step {step_number}: operationmanagement complete - {node_name} is primary and standbys reconfigured", file=sys.stderr)
        sys.stderr.flush()
        
        return jsonify({
            'success': True,
            'message': f'{node_name} has been promoted to primary',
            'new_primary': node_name,
            'status': 'success'
        }), 200
    
    except subprocess.TimeoutExpired as e:
        print(f"[ERROR] Operation timeout: {str(e)}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'error': 'Operation timeout',
            'status': 'timeout'
        }), 504
    except Exception as e:
        print(f"[ERROR] Error promoting {node_name}: {str(e)}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'error': str(e),
            'status': 'error'
        }), 500

def reconfigure_standby(standby_node, primary_node):
    """Reconfigure a node as standby replicating from primary"""
    print(f"\n[Standby Reconfiguration] Starting for {standby_node} (primary: {primary_node})", file=sys.stderr)
    sys.stderr.flush()
    step_number = 1
    
    try:
        standby_container = NODES[standby_node]['container']
        primary_container = NODES[primary_node]['container']
        
        print(f"[Standby Reconfiguration] Step {step_number}: Stopping {standby_container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(['docker', 'stop', standby_container], capture_output=True, text=True, timeout=10)
        print(f"[Standby Reconfiguration] Step {step_number}: Stop result - returncode={result.returncode}", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        time.sleep(2)
        
        print(f"[Standby Reconfiguration] Step {step_number}: Clearing data directory on {standby_container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', standby_container, 'bash', '-c',
             'rm -rf /var/lib/postgresql/data/*'],
            capture_output=True,
            text=True,
            timeout=10
        )
        print(f"[Standby Reconfiguration] Step {step_number}: Clear result - returncode={result.returncode}", file=sys.stderr)
        if result.stderr:
            print(f"[Standby Reconfiguration] Step {step_number}: stderr: {result.stderr}", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        print(f"[Standby Reconfiguration] Step {step_number}: Creating base backup from {primary_container}...", file=sys.stderr)
        sys.stderr.flush()
        backup_cmd = (
            f'PGPASSWORD={DB_CONFIG["password"]} pg_basebackup '
            f'-h {primary_container} -U {DB_CONFIG["user"]} '
            f'-D /var/lib/postgresql/data -P -R'
        )
        result = subprocess.run(
            ['docker', 'exec', standby_container, 'bash', '-c', backup_cmd],
            capture_output=True,
            text=True,
            timeout=60
        )
        print(f"[Standby Reconfiguration] Step {step_number}: Base backup result - returncode={result.returncode}", file=sys.stderr)
        if result.returncode != 0:
            print(f"[Standby Reconfiguration] Step {step_number}: stderr: {result.stderr}", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        print(f"[Standby Reconfiguration] Step {step_number}: Creating standby.signal file...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', standby_container, 'bash', '-c',
             'touch /var/lib/postgresql/data/standby.signal'],
            capture_output=True,
            text=True,
            timeout=10
        )
        print(f"[Standby Reconfiguration] Step {step_number}: Standby signal result - returncode={result.returncode}", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        print(f"[Standby Reconfiguration] Step {step_number}: Starting {standby_container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(['docker', 'start', standby_container], capture_output=True, text=True, timeout=10)
        print(f"[Standby Reconfiguration] Step {step_number}: Start result - returncode={result.returncode}", file=sys.stderr)
        sys.stderr.flush()
        
        time.sleep(5)
        
        step_number += 1
        print(f"[Standby Reconfiguration] Step {step_number}: Verifying standby status for {standby_node}...", file=sys.stderr)
        sys.stderr.flush()
        status = get_node_status(standby_node)
        print(f"[Standby Reconfiguration] Step {step_number}: Verification result: {status}", file=sys.stderr)
        sys.stderr.flush()
        
        print(f"[Standby Reconfiguration] Successfully reconfigured {standby_node} as standby", file=sys.stderr)
        sys.stderr.flush()

    except subprocess.TimeoutExpired as e:
        print(f"[ERROR] reconfigure_standby timeout for {standby_node}: {str(e)}", file=sys.stderr)
        sys.stderr.flush()
    except Exception as e:
        print(f"[ERROR] reconfigure_standby error for {standby_node}: {str(e)}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()

@app.route('/api/operationmanagement/primary', methods=['POST'])
def execute_operationmanagement():
    """Execute operationmanagement with data from request"""
    print(f"\n[API] POST /api/operationmanagement/primary", file=sys.stderr)
    sys.stderr.flush()
    data = request.get_json()
    new_primary = data.get('new_primary')
    print(f"[DEBUG] Requested new_primary: {new_primary}", file=sys.stderr)
    sys.stderr.flush()
    
    if not new_primary:
        print(f"[ERROR] Missing new_primary parameter", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'new_primary parameter required'}), 400
    
    return promote_node(new_primary)


@app.route('/api/operationmanagement/demote/<node_name>', methods=['POST'])
def demote_node(node_name):
    """Demote a primary node to standby"""
    print(f"\n[API] POST /api/operationmanagement/demote/{node_name}", file=sys.stderr)
    sys.stderr.flush()
    
    if node_name not in NODES:
        print(f"[ERROR] Invalid node name: {node_name}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Invalid node name'}), 400
    
    # Prevent replicas from being demoted (they are already standby)
    if NODES[node_name].get('is_replica', False):
        print(f"[ERROR] Cannot demote replica node {node_name} - replicas are always standby", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': f'Replica nodes are always standby (node {node_name} is a replica)'}), 400
    
    try:
        container = NODES[node_name]['container']
        print(f"[API] Demoting {node_name} ({container}) to standby", file=sys.stderr)
        sys.stderr.flush()
        
        # Create standby.signal file
        print(f"[API] Creating standby.signal on {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c',
             'touch /var/lib/postgresql/data/standby.signal'],
            capture_output=True,
            text=True,
            timeout=20
        )
        print(f"[API] standby.signal result: {result.returncode}", file=sys.stderr)
        if result.returncode != 0 and result.stderr:
            print(f"[API] stderr: {result.stderr}", file=sys.stderr)
        sys.stderr.flush()
        
        time.sleep(1)
        
        # Restart the container to enter standby mode
        print(f"[API] Restarting {node_name} container to enter standby mode...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'restart', container],
            capture_output=True,
            text=True,
            timeout=60
        )
        print(f"[API] Restart result: {result.returncode}", file=sys.stderr)
        sys.stderr.flush()
        
        time.sleep(2)
        
        # Verify demotion by checking if node is now standby
        print(f"[API] Verifying demotion...", file=sys.stderr)
        sys.stderr.flush()
        status = get_node_status(node_name)
        is_primary = status.get('is_primary', False)
        print(f"[API] Verification result - is_primary: {is_primary}", file=sys.stderr)
        sys.stderr.flush()
        
        if not is_primary:
            print(f"[API] Demotion successful for {node_name}", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'status': 'success',
                'node': node_name,
                'message': f'{node_name} demoted to standby',
                'is_primary': False
            }), 200
        else:
            print(f"[API] Demotion verification failed - node is still primary", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'status': 'failed',
                'node': node_name,
                'message': f'{node_name} demotion failed - still primary',
                'is_primary': True
            }), 500
    
    except subprocess.TimeoutExpired as e:
        print(f"[ERROR] Timeout during demotion: {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Timeout during demotion', 'status': 'timeout'}), 500
    except Exception as e:
        print(f"[ERROR] Exception during demotion: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e), 'status': 'error'}), 500

@app.route('/api/operationmanagement/demote-all', methods=['POST'])
def demote_all():
    """Demote all nodes to standby (remove primary)"""
    print(f"\n[API] POST /api/operationmanagement/demote-all", file=sys.stderr)
    sys.stderr.flush()
    
    try:
        current_primary = get_current_primary()
        print(f"[Demote All] Current primary: {current_primary}", file=sys.stderr)
        sys.stderr.flush()
        
        # No need to check for primary - demote all works regardless
        
        step_number = 1
        print(f"[Demote All] Step {step_number}: Starting demotion of ALL nodes", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        # Demote ALL nodes (not just the primary) to ensure all have standby.signal
        for node_name in NODES:
            node_container = NODES[node_name]['container']
            print(f"[Demote All] Step {step_number}: Adding standby.signal to {node_name} ({node_container})...", file=sys.stderr)
            sys.stderr.flush()
            
            # Create the standby.signal file using docker exec
            result = subprocess.run(
                ['docker', 'exec', node_container, 'bash', '-c',
                 'touch /var/lib/postgresql/data/standby.signal'],
                capture_output=True,
                text=True,
                timeout=60
            )
            print(f"[Demote All] Step {step_number}: Standby signal result - returncode={result.returncode}", file=sys.stderr)
            if result.returncode != 0:
                print(f"[Demote All] Step {step_number}: stderr: {result.stderr}", file=sys.stderr)
            sys.stderr.flush()
            step_number += 1
        
        # Restart all nodes to make them standby
        print(f"[Demote All] Step {step_number}: Restarting all nodes as standby...", file=sys.stderr)
        sys.stderr.flush()
        for node_name in NODES:
            node_container = NODES[node_name]['container']
            result = subprocess.run(['docker', 'restart', node_container], capture_output=True, text=True, timeout=60)
            print(f"[Demote All] Step {step_number}: {node_name} restart result - returncode={result.returncode}", file=sys.stderr)
            sys.stderr.flush()
        step_number += 1
        
        # Short wait for nodes to start recovery
        time.sleep(2)
        
        step_number += 1
        print(f"[Demote All] Step {step_number}: Returning success (nodes are being restarted as standby)...", file=sys.stderr)
        sys.stderr.flush()
        
        # Return success immediately - nodes will transition to standby on restart
        print(f"[Demote All] SUCCESS - All nodes have been restarted with standby.signal", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'success': True,
            'message': 'All nodes demoted to standby',
            'status': 'success'
        }), 200
    
    except subprocess.TimeoutExpired as e:
        print(f"[ERROR] demote_all timeout: {str(e)}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'error': 'Operation timeout',
            'status': 'timeout'
        }), 504
    except Exception as e:
        print(f"[ERROR] demote_all error: {str(e)}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'error': str(e),
            'status': 'error'
        }), 500

@app.route('/api/operationmanagement/nodes', methods=['GET'])
def get_nodes():
    """Get list of all nodes"""
    print(f"\n[API] GET /api/operationmanagement/nodes", file=sys.stderr)
    sys.stderr.flush()
    nodes = []
    
    for node_name in ['node1', 'node2', 'node3']:
        print(f"[DEBUG] Getting status for {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        status = get_node_status(node_name)
        print(f"[DEBUG] {node_name} status: {status}", file=sys.stderr)
        sys.stderr.flush()
        
        nodes.append({
            'name': node_name,
            'container': NODES[node_name]['container'],
            'port': NODES[node_name]['port'],
            'status': status.get('status'),
            'is_primary': status.get('is_primary')
        })
    
    print(f"[API] Returning {len(nodes)} nodes", file=sys.stderr)
    sys.stderr.flush()
    return jsonify({
        'nodes': nodes
    }), 200

def get_replication_gap():
    """Get replication gap from primary to standby nodes"""
    try:
        gaps = {}
        
        # Find the current primary and get its LSN
        primary_name = None
        primary_lsn = None
        primary_lsn_bytes = None
        
        for name, info in NODES.items():
            try:
                config = DB_CONFIG.copy()
                config['host'] = info['container']
                config['port'] = 5432
                conn = psycopg2.connect(**config, connect_timeout=2)
                cur = conn.cursor(cursor_factory=RealDictCursor)
                
                # Check if this is primary
                cur.execute("SELECT pg_is_in_recovery();")
                is_standby = cur.fetchone()[0]
                
                if not is_standby:
                    # This is the primary
                    primary_name = name
                    cur.execute("SELECT pg_current_wal_lsn()::text as lsn;")
                    result = cur.fetchone()
                    primary_lsn = result['lsn'] if result else '0/0'
                    
                    # Convert LSN to bytes for gap calculation
                    try:
                        cur.execute("SELECT ('0/' || lpad(split_part(pg_current_wal_lsn()::text, '/', 2), '8', '0'))::pg_lsn::bigint as lsn_bytes;")
                        result = cur.fetchone()
                        primary_lsn_bytes = result['lsn_bytes'] if result else 0
                    except:
                        primary_lsn_bytes = 0
                    
                    print(f"[DEBUG] Found primary: {name} at LSN {primary_lsn} ({primary_lsn_bytes} bytes)", file=sys.stderr)
                
                conn.close()
            except Exception as e:
                print(f"[DEBUG] Could not check {name}: {e}", file=sys.stderr)
                continue
        
        # If we found a primary with valid LSN, get replica gaps
        if primary_lsn and primary_lsn != '0/0' and primary_name:
            # Add gap info for primary node itself (0 gap)
            gaps[primary_name] = {
                'primary_lsn': primary_lsn,
                'receive_lsn': primary_lsn,
                'gap_bytes': 0
            }
            
            # Get gap for all other nodes
            for name, info in NODES.items():
                if name == primary_name:
                    continue
                
                try:
                    config = DB_CONFIG.copy()
                    config['host'] = info['container']
                    config['port'] = 5432
                    conn = psycopg2.connect(**config, connect_timeout=2)
                    cur = conn.cursor(cursor_factory=RealDictCursor)
                    
                    # Get receive LSN for replica
                    cur.execute("SELECT pg_last_wal_receive_lsn()::text as lsn;")
                    result = cur.fetchone()
                    replica_lsn = result['lsn'] if result else '0/0'
                    
                    # Try to calculate gap in bytes
                    gap_bytes = 0
                    if replica_lsn and replica_lsn != '0/0':
                        try:
                            cur.execute("SELECT ('0/' || lpad(split_part(pg_last_wal_receive_lsn()::text, '/', 2), '8', '0'))::pg_lsn::bigint as lsn_bytes;")
                            result = cur.fetchone()
                            replica_lsn_bytes = result['lsn_bytes'] if result else 0
                            gap_bytes = primary_lsn_bytes - replica_lsn_bytes if primary_lsn_bytes and replica_lsn_bytes else 0
                        except:
                            gap_bytes = 0
                    
                    gaps[name] = {
                        'primary_lsn': primary_lsn,
                        'receive_lsn': replica_lsn,
                        'gap_bytes': gap_bytes
                    }
                    print(f"[DEBUG] Node {name} LSN: {replica_lsn}, gap: {gap_bytes} bytes", file=sys.stderr)
                    
                    conn.close()
                except Exception as e:
                    # If we can't calculate exact gap, show the LSN values at least
                    gaps[name] = {
                        'primary_lsn': primary_lsn,
                        'receive_lsn': '0/0',
                        'gap_bytes': 0
                    }
                    print(f"[DEBUG] Could not get gap for {name}: {e}", file=sys.stderr)
        else:
            # No active primary, return consistent gaps for all nodes
            for name in NODES:
                gaps[name] = {
                    'primary_lsn': '0/0',
                    'receive_lsn': '0/0',
                    'gap_bytes': 0
                }
        
        return gaps
    except Exception as e:
        print(f"[ERROR] Error getting replication gap: {e}", file=sys.stderr)
        sys.stderr.flush()
        return {}

@app.route('/api/operationmanagement/hosts', methods=['POST'])
def add_host():
    """Add a new PostgreSQL host"""
    print(f"\n[API] POST /api/operationmanagement/hosts - Add new host", file=sys.stderr)
    sys.stderr.flush()
    
    try:
        data = request.get_json()
        
        # Validate required fields
        required_fields = ['name', 'ip', 'port', 'type']
        for field in required_fields:
            if field not in data:
                return jsonify({'error': f'Missing required field: {field}'}), 400
        
        name = data['name']
        ip = data['ip']
        port = data['port']
        host_type = data['type']  # 'backup' or 'replica'
        
        # Validate type
        if host_type not in ['backup', 'replica']:
            return jsonify({'error': 'Type must be either "backup" or "replica"'}), 400
        
        # Check if name already exists
        if name in NODES:
            return jsonify({'error': f'Node {name} already exists'}), 400
        
        # Generate container name from IP or use provided name
        container_name = f"postgres-{name}"
        
        # Add to NODES dictionary
        NODES[name] = {
            'container': container_name,
            'port': port,
            'type': host_type,
            'is_replica': host_type == 'replica',
            'ip': ip
        }
        
        print(f"[API] Successfully added host {name} ({ip}:{port}) as type {host_type}", file=sys.stderr)
        sys.stderr.flush()
        
        return jsonify({
            'status': 'success',
            'message': f'Host {name} added successfully',
            'host': {
                'name': name,
                'ip': ip,
                'port': port,
                'type': host_type,
                'container': container_name
            }
        }), 201
        
    except Exception as e:
        print(f"[ERROR] Exception in add_host(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/hosts/<identifier>', methods=['DELETE'])
def delete_host(identifier):
    """Delete a PostgreSQL host by name or IP"""
    print(f"\n[API] DELETE /api/operationmanagement/hosts/{identifier}", file=sys.stderr)
    sys.stderr.flush()
    
    try:
        # Find host by name or IP
        target_node = None
        
        # First try to find by name
        if identifier in NODES:
            target_node = identifier
        else:
            # Try to find by IP
            for node_name, node_info in NODES.items():
                if node_info.get('ip') == identifier or node_info.get('container') == identifier:
                    target_node = node_name
                    break
        
        if not target_node:
            return jsonify({'error': f'Host not found: {identifier}'}), 404
        
        # Prevent deletion of nodes that are currently primary
        node_status = get_node_status(target_node)
        if node_status.get('is_primary'):
            return jsonify({'error': f'Cannot delete primary node {target_node}. Promote another node first.'}), 400
        
        # Store node info before deletion
        deleted_node = NODES[target_node].copy()
        
        # Remove from NODES
        del NODES[target_node]
        
        print(f"[API] Successfully deleted host {target_node}", file=sys.stderr)
        sys.stderr.flush()
        
        return jsonify({
            'status': 'success',
            'message': f'Host {target_node} deleted successfully',
            'deleted_host': {
                'name': target_node,
                'ip': deleted_node.get('ip', 'N/A'),
                'port': deleted_node.get('port'),
                'type': deleted_node.get('type')
            }
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Exception in delete_host(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/db-clusters', methods=['GET', 'POST'])
def manage_db_clusters():
    """Get all clusters or create a new cluster"""
    if request.method == 'GET':
        # Get all clusters
        try:
            print(f"\n[API] GET /api/operationmanagement/db-clusters", file=sys.stderr)
            sys.stderr.flush()
            
            clusters_list = []
            for cluster_name, cluster_data in DB_CLUSTERS.items():
                cluster_info = {
                    'id': cluster_data['id'],
                    'name': cluster_name,
                    'description': cluster_data.get('description', ''),
                    'created_at': cluster_data.get('created_at'),
                    'nodes': []
                }
                
                # Get details for each node in cluster
                for node_name in cluster_data.get('nodes', []):
                    if node_name in NODES:
                        node_info = NODES[node_name]
                        cluster_info['nodes'].append({
                            'name': node_name,
                            'type': node_info.get('type', 'backup'),
                            'container': node_info['container'],
                            'status': get_node_status(node_name).get('status', 'unknown')
                        })
                
                clusters_list.append(cluster_info)
            
            print(f"[API] Returning {len(clusters_list)} clusters", file=sys.stderr)
            sys.stderr.flush()
            
            return jsonify({'clusters': clusters_list}), 200
        except Exception as e:
            print(f"[ERROR] Exception in manage_db_clusters() GET: {e}", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({'error': str(e)}), 500
    
    elif request.method == 'POST':
        # Create a new database cluster
        try:
            print(f"\n[API] POST /api/operationmanagement/db-clusters", file=sys.stderr)
            sys.stderr.flush()
            
            data = request.get_json()
            
            # Validate required fields
            if not data:
                return jsonify({'error': 'No JSON data provided'}), 400
            
            cluster_name = data.get('name')
            if not cluster_name:
                return jsonify({'error': 'Cluster name is required'}), 400
            
            # Check if cluster already exists
            if cluster_name in DB_CLUSTERS:
                return jsonify({'error': f'Cluster "{cluster_name}" already exists'}), 400
            
            # Create new cluster
            cluster_id = f"cluster_{int(time.time() * 1000)}"
            DB_CLUSTERS[cluster_name] = {
                'id': cluster_id,
                'name': cluster_name,
                'created_at': time.time(),
                'nodes': [],
                'description': data.get('description', '')
            }
            
            print(f"[API] Created database cluster: {cluster_name} ({cluster_id})", file=sys.stderr)
            sys.stderr.flush()
            
            return jsonify({
                'status': 'success',
                'message': f'Cluster "{cluster_name}" created successfully',
                'cluster': DB_CLUSTERS[cluster_name]
            }), 201
            
        except Exception as e:
            print(f"[ERROR] Exception in manage_db_clusters() POST: {e}", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/db-clusters-old', methods=['POST'])
def create_db_cluster_old():
    """Create a new database cluster"""
    try:
        print(f"\n[API] POST /api/operationmanagement/db-clusters", file=sys.stderr)
        sys.stderr.flush()
        
        data = request.get_json()
        
        # Validate required fields
        if not data:
            return jsonify({'error': 'No JSON data provided'}), 400
        
        cluster_name = data.get('name')
        if not cluster_name:
            return jsonify({'error': 'Cluster name is required'}), 400
        
        # Check if cluster already exists
        if cluster_name in DB_CLUSTERS:
            return jsonify({'error': f'Cluster "{cluster_name}" already exists'}), 400
        
        # Create new cluster
        cluster_id = f"cluster_{int(time.time() * 1000)}"
        DB_CLUSTERS[cluster_name] = {
            'id': cluster_id,
            'name': cluster_name,
            'created_at': time.time(),
            'nodes': [],
            'description': data.get('description', '')
        }
        
        print(f"[API] Created database cluster: {cluster_name} ({cluster_id})", file=sys.stderr)
        sys.stderr.flush()
        
        return jsonify({
            'status': 'success',
            'message': f'Cluster "{cluster_name}" created successfully',
            'cluster': DB_CLUSTERS[cluster_name]
        }), 201
        
    except Exception as e:
        print(f"[ERROR] Exception in create_db_cluster(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/db-clusters/<cluster_name>/nodes', methods=['POST'])
def connect_node_to_cluster(cluster_name):
    """Connect a PostgreSQL node to a database cluster"""
    try:
        print(f"\n[API] POST /api/operationmanagement/db-clusters/{cluster_name}/nodes", file=sys.stderr)
        sys.stderr.flush()
        
        # Check if cluster exists
        if cluster_name not in DB_CLUSTERS:
            return jsonify({'error': f'Cluster "{cluster_name}" not found'}), 404
        
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data provided'}), 400
        
        node_name = data.get('node_name')
        if not node_name:
            return jsonify({'error': 'node_name is required'}), 400
        
        # Check if node exists
        if node_name not in NODES:
            return jsonify({'error': f'Node "{node_name}" not found'}), 404
        
        # Check if node already connected to another cluster
        if NODES[node_name].get('db_cluster'):
            old_cluster = NODES[node_name]['db_cluster']
            return jsonify({'error': f'Node "{node_name}" is already connected to cluster "{old_cluster}"'}), 400
        
        # Connect node to cluster
        NODES[node_name]['db_cluster'] = cluster_name
        DB_CLUSTERS[cluster_name]['nodes'].append(node_name)
        
        print(f"[API] Connected node {node_name} to cluster {cluster_name}", file=sys.stderr)
        sys.stderr.flush()
        
        return jsonify({
            'status': 'success',
            'message': f'Node "{node_name}" connected to cluster "{cluster_name}"',
            'cluster': DB_CLUSTERS[cluster_name]
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Exception in connect_node_to_cluster(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/db-clusters/<cluster_name>/nodes/<node_name>', methods=['DELETE'])
def disconnect_node_from_cluster(cluster_name, node_name):
    """Remove a PostgreSQL node from a database cluster"""
    try:
        print(f"\n[API] DELETE /api/operationmanagement/db-clusters/{cluster_name}/nodes/{node_name}", file=sys.stderr)
        sys.stderr.flush()
        
        # Check if cluster exists
        if cluster_name not in DB_CLUSTERS:
            return jsonify({'error': f'Cluster "{cluster_name}" not found'}), 404
        
        # Check if node exists
        if node_name not in NODES:
            return jsonify({'error': f'Node "{node_name}" not found'}), 404
        
        # Check if node is in this cluster
        if NODES[node_name].get('db_cluster') != cluster_name:
            current_cluster = NODES[node_name].get('db_cluster')
            if current_cluster:
                return jsonify({'error': f'Node "{node_name}" is not in cluster "{cluster_name}" (currently in "{current_cluster}")'}), 400
            else:
                return jsonify({'error': f'Node "{node_name}" is not connected to any cluster'}), 400
        
        # Disconnect node from cluster
        NODES[node_name]['db_cluster'] = None
        if node_name in DB_CLUSTERS[cluster_name]['nodes']:
            DB_CLUSTERS[cluster_name]['nodes'].remove(node_name)
        
        print(f"[API] Disconnected node {node_name} from cluster {cluster_name}", file=sys.stderr)
        sys.stderr.flush()
        
        return jsonify({
            'status': 'success',
            'message': f'Node "{node_name}" removed from cluster "{cluster_name}"',
            'cluster': DB_CLUSTERS[cluster_name]
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Exception in disconnect_node_from_cluster(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/overview', methods=['GET'])
def overview():
    """Get comprehensive cluster overview with all node information"""
    try:
        print(f"\n[API] GET /api/operationmanagement/overview", file=sys.stderr)
        sys.stderr.flush()
        
        overview_data = {
            'timestamp': time.time(),
            'cluster_status': 'healthy',
            'nodes': [],
            'primary_node': None
        }
        
        # Get status for all nodes
        statuses = {}
        for node_name in NODES:
            try:
                print(f"[API] Getting status for {node_name}...", file=sys.stderr)
                sys.stderr.flush()
                status = get_node_status(node_name)
                statuses[node_name] = status
            except Exception as e:
                print(f"[ERROR] Error getting status for {node_name}: {e}", file=sys.stderr)
                sys.stderr.flush()
                statuses[node_name] = {'status': 'error', 'is_primary': False}
        
        # Determine primary
        primary_node = None
        for node_name in NODES:
            if statuses[node_name].get('is_primary'):
                primary_node = node_name
                break
        
        overview_data['primary_node'] = primary_node
        print(f"[API] Primary node: {primary_node}", file=sys.stderr)
        sys.stderr.flush()
        
        # Get replication gap
        print(f"[API] Getting replication gap info...", file=sys.stderr)
        sys.stderr.flush()
        gap_info = get_replication_gap()
        print(f"[API] Gap info: {gap_info}", file=sys.stderr)
        sys.stderr.flush()
        
        # Build node list
        for node_name in NODES:
            try:
                node_info = NODES[node_name]
                status = statuses[node_name]
                is_primary = status.get('is_primary', False)
                is_replica = node_info.get('is_replica', False)
                
                node_detail = {
                    'name': node_name,
                    'container': node_info['container'],
                    'hostname': node_info.get('hostname', node_info['container']),
                    'ip_address': node_info.get('ip_address', 'unknown'),
                    'port': node_info['port'],
                    'type': node_info.get('type', 'backup'),  # 'backup' or 'replica'
                    'is_replica': is_replica,
                    'status': status.get('status', 'unknown'),
                    'role': 'PRIMARY' if is_primary else 'STANDBY',
                    'is_primary': is_primary,
                    'connected': status.get('status') == 'connected',
                    'db_cluster': node_info.get('db_cluster', None) or 'none'
                }
                
                # Add gap information for all standbys
                if not is_primary:
                    if node_name in gap_info:
                        node_detail['replication_gap'] = gap_info[node_name]
                    else:
                        # Include gap info even if not found (unavailable)
                        node_detail['replication_gap'] = {
                            'primary_lsn': 'unavailable',
                            'receive_lsn': 'unavailable',
                            'gap_bytes': -1
                        }
                
                overview_data['nodes'].append(node_detail)
                print(f"[API] Added node {node_name}: {node_detail}", file=sys.stderr)
                sys.stderr.flush()
            except Exception as e:
                print(f"[ERROR] Error building node detail for {node_name}: {e}", file=sys.stderr)
                sys.stderr.flush()
                continue
        
        print(f"[API] Returning overview with {len(overview_data['nodes'])} nodes, primary={primary_node}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify(overview_data), 200
    except Exception as e:
        print(f"[ERROR] Exception in overview(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


@app.route('/api/operationmanagement/database-info', methods=['GET'])
def database_info():
    """Get database information: hosts, IPs, and table row counts"""
    try:
        print(f"\n[API] GET /api/operationmanagement/database-info", file=sys.stderr)
        sys.stderr.flush()
        
        database_info_data = {
            'timestamp': time.time(),
            'hosts': {}
        }
        
        # Get primary node info
        primary_node = None
        primary_status = None
        for node_name, node_config in NODES.items():
            status = get_node_status(node_name)
            if status.get('is_primary'):
                primary_node = node_name
                primary_status = status
                break
        
        if not primary_node:
            return jsonify({'error': 'No primary node found'}), 500
        
        # Connect to primary to get table information
        primary_config = NODES[primary_node]
        try:
            # Use container name for internal Docker communication
            conn = psycopg2.connect(
                host=primary_config['container'],
                port=5432,  # Internal Docker port (all nodes listen on 5432 internally)
                user=DB_CONFIG['user'],
                password=DB_CONFIG['password'],
                database=DB_CONFIG['database'],
                connect_timeout=5
            )
            cursor = conn.cursor(cursor_factory=RealDictCursor)
            
            # Check if testdb exists, otherwise use postgres database
            cursor.execute("SELECT datname FROM pg_database WHERE datname='testdb'")
            testdb_exists = cursor.fetchone() is not None
            
            # If testdb doesn't exist, reconnect to postgres database
            target_db = 'testdb' if testdb_exists else 'postgres'
            if not testdb_exists:
                cursor.close()
                conn.close()
                conn = psycopg2.connect(
                    host=primary_config['container'],
                    port=5432,
                    user=DB_CONFIG['user'],
                    password=DB_CONFIG['password'],
                    database='postgres',  # Use postgres database if testdb doesn't exist
                    connect_timeout=5
                )
                cursor = conn.cursor(cursor_factory=RealDictCursor)
            
            # Query table row counts
            cursor.execute("""
                SELECT schemaname, tablename 
                FROM pg_tables 
                WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
                ORDER BY tablename
            """)
            tables = cursor.fetchall()
            
            table_counts = {}
            for table in tables:
                schema = table.get('schemaname', 'public')
                table_name = table.get('tablename')
                full_table_name = f"{schema}.{table_name}"
                
                try:
                    cursor.execute(f"SELECT COUNT(*) as cnt FROM {full_table_name}")
                    count = cursor.fetchone()['cnt']
                    table_counts[table_name] = count
                except Exception as e:
                    print(f"[WARNING] Could not count rows in {full_table_name}: {e}", file=sys.stderr)
                    table_counts[table_name] = -1
            
            cursor.close()
            conn.close()
            
        except Exception as e:
            print(f"[ERROR] Could not connect to primary node: {e}", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({'error': f'Could not connect to primary: {str(e)}'}), 500
        
        # Build response structure: hosts with IP and tables
        for node_name, node_config in NODES.items():
            hostname = node_config.get('hostname', node_config['container'])
            ip_address = node_config.get('ip_address', 'unknown')
            
            # Create host entry if not exists
            if hostname not in database_info_data['hosts']:
                database_info_data['hosts'][hostname] = {
                    'ip_address': ip_address,
                    'tables': {}
                }
            
            # For primary node, add table counts
            if node_name == primary_node:
                database_info_data['hosts'][hostname]['tables'] = table_counts
        
        print(f"[API] Database info compiled with {len(database_info_data['hosts'])} hosts", file=sys.stderr)
        sys.stderr.flush()
        return jsonify(database_info_data), 200
        
    except Exception as e:
        print(f"[ERROR] Exception in database_info(): {e}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    print("\n" + "="*60)
    print("PostgreSQL operationmanagement Service - Starting")
    print("="*60)
    print("Available endpoints:")
    print("  GET    /health                              - Health check")
    print("  GET    /api/operationmanagement/status      - Get cluster status")
    print("  GET    /api/operationmanagement/status/<node> - Get node status")
    print("  GET    /api/operationmanagement/nodes       - Get list of nodes")
    print("  GET    /api/operationmanagement/overview    - Get comprehensive overview")
    print("  GET    /api/operationmanagement/database-info - Get database info (hosts, IPs, tables)")
    print("  POST   /api/operationmanagement/promote/<node> - Promote node to primary")
    print("  POST   /api/operationmanagement/primary     - Set primary node (JSON body)")
    print("  POST   /api/operationmanagement/demote-all  - Demote all nodes to standby")
    print("  POST   /api/operationmanagement/hosts      - Add new host (JSON: name,ip,port,type)")
    print("  DELETE /api/operationmanagement/hosts/<id>  - Delete host by name or IP")
    print("  POST   /api/operationmanagement/db-clusters - Create database cluster (JSON: name,description)")
    print("  POST   /api/operationmanagement/db-clusters/<cluster>/nodes - Connect node to cluster (JSON: node_name)")
    print("  DELETE /api/operationmanagement/db-clusters/<cluster>/nodes/<node> - Disconnect node from cluster")
    print("="*60 + "\n")
    
    app.run(host='0.0.0.0', port=5001, debug=False)
