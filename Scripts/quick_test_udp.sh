#!/bin/bash

# Quick test script for UDP logging system

echo "==================================="
echo "UDP Logging System Quick Test"
echo "==================================="

# Kill any existing server
pkill -9 udp_log_server 2>/dev/null
sleep 1

# Start server
echo "Starting UDP log server..."
cd /Users/jessicahansberry/projects/Rptr
./UDPLogServer/udp_log_server > /tmp/udp_server.log 2>&1 &
SERVER_PID=$!
sleep 2

# Check if server started
if kill -0 $SERVER_PID 2>/dev/null; then
    echo "✓ Server started (PID: $SERVER_PID)"
else
    echo "✗ Server failed to start"
    cat /tmp/udp_server.log
    exit 1
fi

# Send test sequence
echo "Sending test messages..."
python3 - <<EOF
import socket
import time

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

# New session
print("  - NEW_SESSION")
sock.sendto(b"CMD|NEW_SESSION", ("127.0.0.1", 9999))
time.sleep(0.5)

# Test messages
for i in range(10):
    msg = f"TEST|Quick test message {i:03d}"
    sock.sendto(msg.encode(), ("127.0.0.1", 9999))
    
print("  - Sent 10 test messages")
time.sleep(0.5)

# End session
print("  - END_SESSION")
sock.sendto(b"CMD|END_SESSION", ("127.0.0.1", 9999))
sock.close()
EOF

sleep 2

# Check results
echo ""
echo "Checking results..."

# Check for log files
if [ -d "UDPLogServer/log_sessions" ]; then
    SESSION_COUNT=$(ls UDPLogServer/log_sessions/*.log 2>/dev/null | wc -l | tr -d ' ')
    if [ "$SESSION_COUNT" -gt 0 ]; then
        echo "✓ Found $SESSION_COUNT session file(s)"
        LATEST_LOG=$(ls -t UDPLogServer/log_sessions/*.log | head -1)
        echo "  Latest: $(basename $LATEST_LOG)"
        
        # Count messages in latest log
        MSG_COUNT=$(grep -c "TEST|" "$LATEST_LOG" 2>/dev/null || echo "0")
        if [ "$MSG_COUNT" -eq 10 ]; then
            echo "✓ All 10 messages logged"
        else
            echo "✗ Only $MSG_COUNT/10 messages found"
        fi
    else
        echo "✗ No session files created"
    fi
else
    echo "✗ No log_sessions directory"
fi

# Check symlink
if [ -L "UDPLogServer/unified_stream.log" ]; then
    echo "✓ Symlink exists"
else
    echo "✗ No symlink found"
fi

# Clean up
kill $SERVER_PID 2>/dev/null
wait $SERVER_PID 2>/dev/null

echo ""
echo "Test complete!"
echo "Server log: /tmp/udp_server.log"