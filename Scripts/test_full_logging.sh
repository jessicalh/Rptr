#!/bin/bash

# Test Full Logging Chain
# Tests iOS -> UDP and JS -> iOS -> UDP logging

echo "=== Full Logging Chain Test ==="
echo

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 1. Check if UDP server is running
echo "1. Checking UDP server..."
if pgrep -f udp_log_server > /dev/null; then
    echo -e "${GREEN}✓ UDP server is running${NC}"
else
    echo -e "${YELLOW}⚠ UDP server not running. Starting it...${NC}"
    ./UDPLogServer/udp_log_server &
    UDP_PID=$!
    sleep 1
fi

# 2. Start new session
echo
echo "2. Starting new logging session..."
echo "CMD|NEW_SESSION" | nc -u localhost 9999
sleep 0.5
echo -e "${GREEN}✓ Session started${NC}"

# 3. Test direct UDP logging
echo
echo "3. Testing direct UDP logging..."
echo "TEST|Direct UDP test message" | nc -u localhost 9999
sleep 0.1

# 4. Test iOS app logging (simulated)
echo
echo "4. Testing iOS app logging format..."
echo "SERVER|[-INFO] [DIY-HLS] Simulated iOS log message" | nc -u localhost 9999
sleep 0.1

# 5. Test JavaScript logging format
echo
echo "5. Testing JavaScript logging format..."
echo "JS|[INFO] [HLS] Simulated JavaScript log message" | nc -u localhost 9999
sleep 0.1

# 6. Test various log levels
echo
echo "6. Testing different log levels..."
echo "JS|[ERROR] [PLAYER] Simulated error message" | nc -u localhost 9999
echo "JS|[WARN] [BUFFER] Simulated warning message" | nc -u localhost 9999
echo "JS|[INFO] [FRAG] Simulated info message" | nc -u localhost 9999
echo "JS|[DEBUG] [PARSE] Simulated debug message" | nc -u localhost 9999
sleep 0.5

# 7. Check if logs are being written
echo
echo "7. Checking log file..."
if [ -L "unified_stream.log" ]; then
    LINE_COUNT=$(wc -l < unified_stream.log)
    echo -e "${GREEN}✓ Log file exists with $LINE_COUNT lines${NC}"
    
    echo
    echo "Last 10 log entries:"
    echo "-------------------"
    tail -10 unified_stream.log
else
    echo -e "${RED}✗ Log file not found${NC}"
fi

# 8. Test JavaScript HTTP forwarding (if app is running)
echo
echo "8. Testing JavaScript HTTP forwarding..."
echo "Testing connection to iOS app on port 8080..."

# Try to find iOS device IP
IOS_IP=$(ifconfig | grep "inet 172.20" | awk '{print $2}' | head -1)
if [ -z "$IOS_IP" ]; then
    IOS_IP="localhost"
fi

# Test the forward-log endpoint
curl -X POST "http://$IOS_IP:8080/forward-log" \
     -H "Content-Type: text/plain" \
     -d "JS|[TEST] [CURL] Test message via HTTP forward" \
     --max-time 2 \
     --silent \
     --show-error 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ HTTP forwarding endpoint accessible${NC}"
else
    echo -e "${YELLOW}⚠ HTTP forwarding endpoint not accessible (app may not be running)${NC}"
fi

# 9. End session
echo
echo "9. Ending logging session..."
echo "CMD|END_SESSION" | nc -u localhost 9999
sleep 0.5
echo -e "${GREEN}✓ Session ended${NC}"

echo
echo "=== Test Complete ==="
echo
echo "To view full log:"
echo "  cat unified_stream.log"
echo
echo "To monitor logs in real-time:"
echo "  tail -f unified_stream.log"
echo

# Cleanup if we started the server
if [ ! -z "$UDP_PID" ]; then
    echo "Stopping UDP server (PID: $UDP_PID)..."
    kill $UDP_PID 2>/dev/null
fi