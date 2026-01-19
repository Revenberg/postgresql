-- Insert 10 test messages
INSERT INTO messages (from_node_id, to_node_id, message_text, rssi) VALUES
('node1', 'node2', 'Test message 1', -80),
('node1', 'node2', 'Test message 2', -85),
('node1', 'node2', 'Test message 3', -90),
('node2', 'node3', 'Test message 4', -75),
('node2', 'node3', 'Test message 5', -80),
('node3', 'node1', 'Test message 6', -88),
('node3', 'node1', 'Test message 7', -92),
('node1', 'node3', 'Test message 8', -76),
('node2', 'node1', 'Test message 9', -81),
('node3', 'node2', 'Test message 10', -87);
