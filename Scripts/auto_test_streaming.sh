#!/bin/bash

# Automated Streaming Test Script for Claude
# This script allows automated testing of HLS streaming without manual intervention
# Now tests both Firefox and Safari to debug browser-specific issues

set -e

DEVICE_ID="00008020-000140293433002E"
BUNDLE_ID="jlh-test.Rptr"
LOG_FILE="/Users/jessicahansberry/projects/Rptr/logs/current.log"
LOG_SERVER_PATH="/Users/jessicahansberry/projects/Rptr/UDPLogServer"
PROJECT_PATH="/Users/jessicahansberry/projects/Rptr"

echo "=== Automated HLS Streaming Test ==="
echo "Starting at $(date)"

# Function to check if log server is running
check_log_server() {
    if ! lsof -i :9999 > /dev/null 2>&1; then
        echo "Starting UDP log server..."
        cd "$LOG_SERVER_PATH"
        nohup ./udp_log_server > /dev/null 2>&1 &
        sleep 1
    else
        echo "Log server already running"
    fi
}

# Function to clear logs
clear_logs() {
    echo "Clearing logs..."
    rm -f "$LOG_FILE"
    # Send test packet to verify server
    TEST_UUID=$(uuidgen)
    echo "TEST|Starting automated test: $TEST_UUID" | nc -u -w1 localhost 9999
    sleep 0.5
}

# Function to build the app
build_app() {
    echo "Building app..."
    cd "$PROJECT_PATH"
    xcodebuild -project Rptr.xcodeproj -scheme Rptr -configuration Debug -sdk iphoneos -allowProvisioningUpdates > /tmp/build.log 2>&1
    if [ $? -eq 0 ]; then
        echo "Build successful"
    else
        echo "Build failed. Check /tmp/build.log"
        exit 1
    fi
}

# Function to deploy the app
deploy_app() {
    echo "Deploying app to device..."
    APP_PATH="/Users/jessicahansberry/Library/Developer/Xcode/DerivedData/Rptr-dmqjedjmxfamokhhzycaiqnsalab/Build/Products/Debug-iphoneos/Rptr.app"
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"
    sleep 2
}

# Function to launch the app
launch_app() {
    echo "Launching app (with auto-start enabled)..."
    xcrun devicectl device process launch --terminate-existing --device "$DEVICE_ID" "$BUNDLE_ID"
    sleep 3
}

# Function to get stream URL from logs
get_stream_url() {
    # Wait for streaming to start
    echo "Waiting for streaming to start..."
    for i in {1..10}; do
        if grep -q "Streaming URL:" "$LOG_FILE" 2>/dev/null; then
            STREAM_URL=$(grep "Streaming URL:" "$LOG_FILE" | tail -1 | sed 's/.*Streaming URL: //')
            echo "Found stream URL: $STREAM_URL"
            return 0
        fi
        sleep 1
    done
    echo "Timeout waiting for stream URL"
    return 1
}

# Function to open browser with stream
open_browser() {
    local browser="$1"
    if [ -n "$STREAM_URL" ]; then
        echo "Opening $browser with stream..."
        
        if [ "$browser" = "firefox" ]; then
            # Open in Firefox
            if [ -d "/Applications/Firefox.app" ]; then
                open -a Firefox "$STREAM_URL"
            else
                echo "Firefox not installed, skipping Firefox test"
                return 1
            fi
        elif [ "$browser" = "safari" ]; then
            # Open in Safari
            open -a Safari "$STREAM_URL"
        elif [ "$browser" = "chrome" ]; then
            # Open in Chrome
            if [ -d "/Applications/Google Chrome.app" ]; then
                open -a "Google Chrome" "$STREAM_URL"
            else
                echo "Chrome not installed, skipping Chrome test"
                return 1
            fi
        else
            # Default - system browser
            open "$STREAM_URL"
        fi
        
        # Wait for browser to load and start playing
        sleep 5
    fi
}

# Function to check browser-specific logs
check_browser_logs() {
    local browser="$1"
    echo ""
    echo "=== Checking $browser logs ==="
    
    # Count browser-specific log entries
    local log_count=$(grep -c "\[${browser}\]" "$LOG_FILE" 2>/dev/null || echo 0)
    echo "$browser log entries: $log_count"
    
    if [ $log_count -gt 0 ]; then
        echo "Recent $browser activity:"
        grep "\[${browser}\]" "$LOG_FILE" | tail -10
        
        # Check for errors
        local error_count=$(grep "\[${browser}\]" "$LOG_FILE" | grep -c "ERROR\|error\|fail" 2>/dev/null || echo 0)
        if [ $error_count -gt 0 ]; then
            echo "⚠️  $browser errors detected: $error_count"
            grep "\[${browser}\]" "$LOG_FILE" | grep "ERROR\|error\|fail" | tail -5
        else
            echo "✓ No $browser errors detected"
        fi
        
        # Check for successful playback indicators
        if grep "\[${browser}\]" "$LOG_FILE" | grep -q "Video playing\|BUFFER_APPEND\|Fragment loaded" 2>/dev/null; then
            echo "✓ $browser appears to be playing video"
        else
            echo "⚠️  $browser playback status unclear"
        fi
    else
        echo "⚠️  No $browser logs found - browser may not have connected"
    fi
}

# Function to monitor logs for errors
monitor_logs() {
    echo "Monitoring logs for 10 seconds..."
    tail -f "$LOG_FILE" | grep -E "(ERROR|SEGMENT-VALIDATOR|Init segment|tfdt|AVAssetReader|Firefox|Safari|Chrome)" &
    TAIL_PID=$!
    sleep 10
    kill $TAIL_PID 2>/dev/null || true
}

# Function to check segment creation
check_segments() {
    echo "Checking segment creation..."
    SEGMENT_COUNT=$(grep -c "Finalized segment" "$LOG_FILE" 2>/dev/null || echo 0)
    echo "Segments created: $SEGMENT_COUNT"
    
    if [ $SEGMENT_COUNT -gt 0 ]; then
        echo "✓ Segments are being created"
        # Check for validation results
        if grep -q "SEGMENT-VALIDATOR" "$LOG_FILE"; then
            echo "Segment validation results:"
            grep "SEGMENT-VALIDATOR.*Result:" "$LOG_FILE" | tail -5
        fi
    else
        echo "✗ No segments created yet"
    fi
}

# Function to run browser test
test_browser() {
    local browser="$1"
    echo ""
    echo "========================================="
    echo "Testing with $browser"
    echo "========================================="
    
    # Mark test start in log
    echo "TEST|Starting $browser test" | nc -u -w1 localhost 9999
    sleep 0.5
    
    # Open browser
    open_browser "$browser"
    
    # Monitor for a bit
    echo "Monitoring $browser for 8 seconds..."
    sleep 8
    
    # Check browser-specific results
    check_browser_logs "$browser"
    
    # Mark test end
    echo "TEST|Completed $browser test" | nc -u -w1 localhost 9999
}

# Main test sequence
main() {
    echo ""
    echo "Step 1: Ensuring log server is running"
    check_log_server
    
    echo ""
    echo "Step 2: Clearing logs"
    clear_logs
    
    if [ "$1" == "--build" ]; then
        echo ""
        echo "Step 3: Building app"
        build_app
        
        echo ""
        echo "Step 4: Deploying app"
        deploy_app
    fi
    
    echo ""
    echo "Step 5: Launching app with auto-start"
    launch_app
    
    echo ""
    echo "Step 6: Getting stream URL"
    get_stream_url
    
    if [ "$1" == "--browser" ] || [ "$2" == "--browser" ]; then
        # Test Firefox first (known working)
        test_browser "Firefox"
        
        # Test Safari (problematic)
        test_browser "Safari"
        
        # Optionally test Chrome if available
        if [ -d "/Applications/Google Chrome.app" ]; then
            test_browser "Chrome"
        fi
    fi
    
    echo ""
    echo "Step 7: Final monitoring for 5 seconds"
    monitor_logs
    
    echo ""
    echo "Step 8: Checking overall results"
    check_segments
    
    echo ""
    echo "=== Test Complete ==="
    echo "Log file: $LOG_FILE"
    echo ""
    
    # Show summary of key findings
    echo "Summary:"
    echo "--------"
    
    # Browser comparison
    echo ""
    echo "Browser Comparison:"
    for browser in Firefox Safari Chrome; do
        local count=$(grep -c "\[${browser}\]" "$LOG_FILE" 2>/dev/null || echo 0)
        if [ $count -gt 0 ]; then
            local errors=$(grep "\[${browser}\]" "$LOG_FILE" | grep -c "ERROR\|error\|fail" 2>/dev/null || echo 0)
            local playing=$(grep "\[${browser}\]" "$LOG_FILE" | grep -c "Video playing" 2>/dev/null || echo 0)
            echo "  $browser: $count logs, $errors errors, playing=$playing"
        fi
    done
    
    # Validation status
    echo ""
    echo "Validation Status:"
    grep -E "(AVAssetReader validation|SEGMENT-VALIDATOR.*Result)" "$LOG_FILE" | tail -3
}

# Parse arguments
case "$1" in
    --help)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  --build    Build and deploy before testing"
        echo "  --browser  Open and test browsers (Firefox, Safari, Chrome)"
        echo "  --help     Show this help"
        echo ""
        echo "Examples:"
        echo "  $0                    # Just launch app and monitor"
        echo "  $0 --browser          # Launch app and test browsers"
        echo "  $0 --build --browser  # Full build, deploy, and browser test"
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac