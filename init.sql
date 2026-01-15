-- PostgreSQL Initialization Script
-- This script is executed automatically when the container starts for the first time
-- All statements are idempotent and can be safely re-executed

-- Grant replication privilege to testadmin user (created by POSTGRES_USER env var)
DO $$ 
BEGIN
    ALTER USER testadmin WITH REPLICATION;
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

-- Create users table
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create nodes table (for mesh network nodes)
CREATE TABLE IF NOT EXISTS nodes (
    id SERIAL PRIMARY KEY,
    node_id VARCHAR(20) UNIQUE NOT NULL,
    node_name VARCHAR(100),
    latitude DECIMAL(9, 6),
    longitude DECIMAL(9, 6),
    battery_level INT,
    last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create messages table
CREATE TABLE IF NOT EXISTS messages (
    id SERIAL PRIMARY KEY,
    from_node_id VARCHAR(20) NOT NULL,
    to_node_id VARCHAR(20),
    message_text TEXT,
    rssi INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_messages_from_node FOREIGN KEY (from_node_id) REFERENCES nodes(node_id)
);

-- Insert sample data into users table (ignore if already exists)
INSERT INTO users (username, email) VALUES
    ('admin', 'admin@example.com'),
    ('person1', 'person1@example.com'),
    ('person2', 'person2@example.com')
ON CONFLICT (username) DO NOTHING;

-- Insert sample data into nodes table (ignore if already exists)
INSERT INTO nodes (node_id, node_name, latitude, longitude, battery_level) VALUES
    ('NODE001', 'Heltec Node 1', 53.2018, 6.5673, 85),
    ('NODE002', 'Heltec Node 2', 53.2020, 6.5680, 72),
    ('NODE003', 'Gateway Node', 53.2015, 6.5670, 100)
ON CONFLICT (node_id) DO NOTHING;

-- Insert sample data into messages table (ignore if already exists)
INSERT INTO messages (from_node_id, to_node_id, message_text, rssi) VALUES
    ('NODE001', 'NODE002', 'Hello from Node 1', -95),
    ('NODE002', 'NODE001', 'Hello back from Node 2', -98),
    ('NODE001', NULL, 'Broadcast message', -90)
ON CONFLICT DO NOTHING;

-- Create indexes for better query performance (if not already exist)
CREATE INDEX IF NOT EXISTS idx_nodes_node_id ON nodes(node_id);
CREATE INDEX IF NOT EXISTS idx_messages_from_node ON messages(from_node_id);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
