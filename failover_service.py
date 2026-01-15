#!/usr/bin/env python3
"""
PostgreSQL Failover Service
Provides API endpoints to perform failover operations between nodes
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
    'node1': {'container': 'postgres-node1', 'port': 5432},
    'node2': {'container': 'postgres-node2', 'port': 5435},
    'node3': {'container': 'postgres-node3', 'port': 5436},
}

DB_CONFIG = {
    'user': 'testadmin',
    'password': 'securepwd123',
    'database': 'postgres'
}

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
    return jsonify({'status': 'healthy', 'service': 'failover_service'}), 200

@app.route('/api/failover/status', methods=['GET'])
def failover_status():
    """Get current cluster status"""
    print(f"\n[API] GET /api/failover/status", file=sys.stderr)
    sys.stderr.flush()
    status = {}
    for node_name in NODES:
        print(f"[API] Getting status for {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        status[node_name] = get_node_status(node_name)
    
    current_primary = get_current_primary()
    print(f"[API] Current primary: {current_primary}", file=sys.stderr)
    sys.stderr.flush()
    
    result = {
        'nodes': status,
        'current_primary': current_primary,
        'timestamp': time.time()
    }
    print(f"[API] Returning: {result}", file=sys.stderr)
    sys.stderr.flush()
    return jsonify(result), 200

@app.route('/api/failover/status/<node_name>', methods=['GET'])
def get_status(node_name):
    """Get status of a specific node"""
    print(f"\n[API] GET /api/failover/status/{node_name}", file=sys.stderr)
    sys.stderr.flush()
    
    if node_name not in NODES:
        print(f"[ERROR] Invalid node name: {node_name}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Invalid node name'}), 400
    
    status = get_node_status(node_name)
    current_primary = get_current_primary()
    print(f"[API] Current primary: {current_primary}", file=sys.stderr)
    sys.stderr.flush()
    
    result = {
        'node': node_name,
        'status': status,
        'is_current_primary': node_name == current_primary,
        'timestamp': time.time()
    }
    print(f"[API] Returning: {result}", file=sys.stderr)
    sys.stderr.flush()
    return jsonify(result), 200

@app.route('/api/failover/promote/<node_name>', methods=['POST'])
def promote_node(node_name):
    """Promote a node to primary"""
    print(f"\n[API] POST /api/failover/promote/{node_name}", file=sys.stderr)
    sys.stderr.flush()
    if node_name not in NODES:
        print(f"[ERROR] Invalid node name: {node_name}", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({'error': 'Invalid node name'}), 400
    
    # Check current status
    print(f"[DEBUG] Checking current primary...", file=sys.stderr)
    sys.stderr.flush()
    current_primary = get_current_primary()
    print(f"[DEBUG] Current primary: {current_primary}", file=sys.stderr)
    sys.stderr.flush()
    
    if current_primary == node_name:
        print(f"[ERROR] {node_name} is already primary", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'error': f'{node_name} is already primary',
            'status': 'already_primary'
        }), 400
    
    node_status = get_node_status(node_name)
    print(f"[DEBUG] Node status: {node_status}", file=sys.stderr)
    sys.stderr.flush()
    
    if node_status.get('status') != 'connected':
        print(f"[ERROR] {node_name} is not connected", file=sys.stderr)
        sys.stderr.flush()
        return jsonify({
            'error': f'{node_name} is not connected',
            'status': 'not_connected'
        }), 400
    
    try:
        container = NODES[node_name]['container']
        step_number = 1
        
        # Promote the node
        print(f"\n[Failover] Step {step_number}: Starting promotion of {node_name} ({container}) to primary", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        # Resume WAL replay first
        print(f"[Failover] Step {step_number}: Resuming WAL replay on {container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c', 
             f'PGPASSWORD={DB_CONFIG["password"]} psql -U {DB_CONFIG["user"]} -d postgres -c "SELECT pg_wal_replay_resume();"'],
            capture_output=True,
            text=True,
            timeout=10
        )
        print(f"[Failover] Step {step_number}: WAL resume result: returncode={result.returncode}", file=sys.stderr)
        if result.stderr:
            print(f"[Failover] Step {step_number}: stderr: {result.stderr}", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        time.sleep(2)
        
        # Promote using pg_ctl (this will handle removing standby.signal)
        print(f"[Failover] Step {step_number}: Running pg_ctl promote on {container}...", file=sys.stderr)
        sys.stderr.flush()
        result = subprocess.run(
            ['docker', 'exec', container, 'bash', '-c',
             'su - postgres -c "/usr/lib/postgresql/18/bin/pg_ctl promote -D /var/lib/postgresql/data/pgdata"'],
            capture_output=True,
            text=True,
            timeout=10
        )
        
        print(f"[Failover] Step {step_number}: pg_ctl promote result:", file=sys.stderr)
        print(f"[Failover]   returncode={result.returncode}", file=sys.stderr)
        print(f"[Failover]   stdout: {result.stdout if result.stdout else '(empty)'}", file=sys.stderr)
        print(f"[Failover]   stderr: {result.stderr if result.stderr else '(empty)'}", file=sys.stderr)
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
        print(f"[Failover] Step {step_number}: Waiting 5 seconds for promotion to stabilize...", file=sys.stderr)
        sys.stderr.flush()
        time.sleep(5)
        step_number += 1
        
        # Verify promotion
        print(f"[Failover] Step {step_number}: Verifying promotion of {node_name}...", file=sys.stderr)
        sys.stderr.flush()
        verify_status = get_node_status(node_name)
        print(f"[Failover] Step {step_number}: Verification result: {verify_status}", file=sys.stderr)
        sys.stderr.flush()
        
        if not verify_status.get('is_primary'):
            print(f"[ERROR] Step {step_number}: Promotion verification failed - node is not primary", file=sys.stderr)
            sys.stderr.flush()
            return jsonify({
                'error': 'Promotion verification failed',
                'status': 'verification_failed'
            }), 500
        
        step_number += 1
        print(f"[Failover] Step {step_number}: Promotion verification SUCCESSFUL - {node_name} is now primary", file=sys.stderr)
        sys.stderr.flush()
        step_number += 1
        
        # Reconfigure other nodes as standby
        print(f"[Failover] Step {step_number}: Reconfiguring remaining nodes as standby...", file=sys.stderr)
        sys.stderr.flush()
        for other_node in NODES:
            if other_node == node_name:
                continue
            print(f"[Failover] Step {step_number}: Reconfiguring {other_node} as standby...", file=sys.stderr)
            sys.stderr.flush()
            reconfigure_standby(other_node, node_name)
        
        step_number += 1
        print(f"[Failover] Step {step_number}: Failover complete - {node_name} is primary and standbys reconfigured", file=sys.stderr)
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
             'rm -rf /var/lib/postgresql/data/pgdata/*'],
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
            f'-D /var/lib/postgresql/data/pgdata -P -R'
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
             'touch /var/lib/postgresql/data/pgdata/standby.signal'],
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

@app.route('/api/failover/execute', methods=['POST'])
def execute_failover():
    """Execute failover with data from request"""
    print(f"\n[API] POST /api/failover/execute", file=sys.stderr)
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

@app.route('/api/failover/nodes', methods=['GET'])
def get_nodes():
    """Get list of all nodes"""
    print(f"\n[API] GET /api/failover/nodes", file=sys.stderr)
    sys.stderr.flush()
    nodes = []
    current_primary = get_current_primary()
    print(f"[DEBUG] Current primary: {current_primary}", file=sys.stderr)
    sys.stderr.flush()
    
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
            'is_primary': status.get('is_primary'),
            'is_current_primary': node_name == current_primary
        })
    
    print(f"[API] Returning {len(nodes)} nodes", file=sys.stderr)
    sys.stderr.flush()
    return jsonify({
        'nodes': nodes,
        'current_primary': current_primary
    }), 200


if __name__ == '__main__':
    print("\n" + "="*60)
    print("PostgreSQL Failover Service - Starting")
    print("="*60)
    print("Available endpoints:")
    print("  GET  /health                    - Health check")
    print("  GET  /api/failover/status       - Get cluster status")
    print("  GET  /api/failover/status/<node> - Get node status")
    print("  GET  /api/failover/nodes        - Get list of nodes")
    print("  POST /api/failover/promote/<node> - Promote node to primary")
    print("  POST /api/failover/execute      - Execute failover (JSON body)")
    print("="*60 + "\n")
    
    app.run(host='0.0.0.0', port=5001, debug=False)
