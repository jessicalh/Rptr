#!/bin/bash

# Start UDP logging system for development session
# This script ensures the UDP log server is running and ready

echo "============================================"
echo "Starting UDP Logging System"
echo "============================================"

# Kill any existing server
pkill -9 udp_log_server 2>/dev/null
sleep 1

# Clean up old logs (optional - comment out to preserve history)
rm -rf log_sessions unified_stream.log 2>/dev/null

# Start the server
cd /Users/jessicahansberry/projects/Rptr
./UDPLogServer/udp_log_server &
SERVER_PID=$!
sleep 2

# Check if server started
if kill -0 $SERVER_PID 2>/dev/null; then
    echo "✓ UDP Log Server started (PID: $SERVER_PID)"
    echo ""
    echo "Server listening on: 127.0.0.1:9999"
    echo "Log directory: $(pwd)/log_sessions/"
    echo "Current log: $(pwd)/unified_stream.log"
    echo ""
    echo "To view logs in real-time:"
    echo "  tail -f unified_stream.log"
    echo ""
    echo "To stop server:"
    echo "  kill $SERVER_PID"
else
    echo "✗ Failed to start UDP log server"
    exit 1
fi