#!/bin/bash

# Script to discover build machine's WiFi IP and embed it in the iOS app
# This runs as a build phase in Xcode to configure UDP logging target

echo "Discovering UDP log server IP address..."

# Get the WiFi IP address of the build machine
# Try multiple methods to find the IP

# Method 1: Check en0 (typical WiFi interface on macOS)
WIFI_IP=$(ifconfig en0 2>/dev/null | grep 'inet ' | awk '{print $2}')

# Method 2: If en0 doesn't work, try en1
if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ifconfig en1 2>/dev/null | grep 'inet ' | awk '{print $2}')
fi

# Method 3: Use ipconfig if available
if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ipconfig getifaddr en0 2>/dev/null)
fi

if [ -z "$WIFI_IP" ]; then
    WIFI_IP=$(ipconfig getifaddr en1 2>/dev/null)
fi

# Fallback to localhost if no WiFi IP found
if [ -z "$WIFI_IP" ]; then
    echo "Warning: Could not detect WiFi IP, using localhost"
    WIFI_IP="127.0.0.1"
fi

echo "Build machine WiFi IP: $WIFI_IP"

# Generate a header file with the IP address
# If SRCROOT is not set (running manually), use script's parent directory
if [ -z "$SRCROOT" ]; then
    SRCROOT="$(dirname "$(dirname "$(realpath "$0")")")"
fi
OUTPUT_FILE="${SRCROOT}/Rptr/RptrUDPLoggerConfig.h"

cat > "$OUTPUT_FILE" << EOF
//
//  RptrUDPLoggerConfig.h
//  Rptr
//
//  Auto-generated build configuration for UDP logging
//  Generated at build time on $(date)
//

#ifndef RptrUDPLoggerConfig_h
#define RptrUDPLoggerConfig_h

// Build machine's WiFi IP address for UDP logging
#define RPTR_UDP_LOG_SERVER_IP @"${WIFI_IP}"

// UDP log server port (default)
#define RPTR_UDP_LOG_SERVER_PORT 9999

// Build timestamp for debugging
#define RPTR_BUILD_TIMESTAMP @"$(date '+%Y-%m-%d %H:%M:%S')"

// Build machine hostname for reference
#define RPTR_BUILD_MACHINE @"$(hostname -s)"

#endif /* RptrUDPLoggerConfig_h */
EOF

echo "Generated $OUTPUT_FILE with server IP: $WIFI_IP"

# Also create a plist file that can be read at runtime if needed
PLIST_FILE="${SRCROOT}/Rptr/UDPLoggerConfig.plist"

cat > "$PLIST_FILE" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>ServerIP</key>
    <string>${WIFI_IP}</string>
    <key>ServerPort</key>
    <integer>9999</integer>
    <key>BuildTimestamp</key>
    <string>$(date '+%Y-%m-%d %H:%M:%S')</string>
    <key>BuildMachine</key>
    <string>$(hostname)</string>
</dict>
</plist>
EOF

echo "Generated $PLIST_FILE"

# Also generate the JavaScript UDP logger from template
JS_TEMPLATE="${SRCROOT}/Rptr/Resources/udp_logger_template.js"
JS_OUTPUT="${SRCROOT}/Rptr/Resources/udp_logger.js"

if [ -f "$JS_TEMPLATE" ]; then
    echo "Generating JavaScript UDP logger..."
    sed -e "s/%%UDP_LOG_SERVER_IP%%/${WIFI_IP}/g" \
        -e "s/%%BUILD_TIMESTAMP%%/$(date '+%Y-%m-%d %H:%M:%S')/g" \
        -e "s/%%BUILD_MACHINE%%/$(hostname -s)/g" \
        "$JS_TEMPLATE" > "$JS_OUTPUT"
    echo "Generated $JS_OUTPUT with server IP: $WIFI_IP"
fi

echo "UDP logging will target: $WIFI_IP:9999"