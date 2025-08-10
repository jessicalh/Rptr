#!/bin/bash

# Prepare for integration testing
echo "========================================="
echo "Preparing for Integration Test"
echo "========================================="

# 1. Disable UDP logging for now (optional)
echo "1. Making UDP logging optional..."
cat > /tmp/udp_logging_patch.txt << 'EOF'
The UDP logging is configured at build time with a hardcoded IP.
For integration testing, either:
- Run the build script to update the IP: ./Scripts/set_log_server_ip.sh
- Or temporarily disable UDP logging in RptrLogger.m
EOF

# 2. Check network configuration
echo ""
echo "2. Current network configuration:"
echo "   WiFi IP: $(ipconfig getifaddr en0 || echo 'Not connected')"
echo "   Hotspot IP: $(ipconfig getifaddr en1 || echo 'Not active')"

# 3. Update UDP logger config if needed
echo ""
echo "3. Updating UDP logger configuration..."
./Scripts/set_log_server_ip.sh

# 4. Build check
echo ""
echo "4. Checking build configuration..."
xcodebuild -project Rptr.xcodeproj -showBuildSettings | grep -E "DEVELOPMENT_TEAM|CODE_SIGN" | head -5

echo ""
echo "========================================="
echo "Integration Test Checklist:"
echo "========================================="
echo ""
echo "[ ] 1. Fix Xcode provisioning profile:"
echo "       - Open Rptr.xcodeproj in Xcode"
echo "       - Select your development team"
echo "       - Select your iOS device in device list"
echo ""
echo "[ ] 2. Ensure iOS device and Mac on same WiFi network"
echo ""
echo "[ ] 3. Start UDP log server (optional):"
echo "       ./Scripts/start_logging.sh"
echo ""
echo "[ ] 4. Build and run on iOS device:"
echo "       - Xcode: Product > Run (Cmd+R)"
echo ""
echo "[ ] 5. Note the server URL shown in app"
echo ""
echo "[ ] 6. Open URL in browser on another device"
echo ""
echo "[ ] 7. Monitor logs (if UDP server running):"
echo "       tail -f unified_stream.log"
echo ""
echo "========================================="
echo "Known Issues to Expect:"
echo "========================================="
echo "- UDP logging may fail if on different network"
echo "- WebSocket connection errors in browser console (non-critical)"
echo "- First segment may take 3-6 seconds to appear"
echo ""