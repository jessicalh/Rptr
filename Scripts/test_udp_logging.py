#!/usr/bin/env python3
"""
UDP Logging System Test Suite
Tests server startup, high-rate logging, and log integrity
"""

import socket
import threading
import time
import subprocess
import os
import sys
import signal
from pathlib import Path

# Configuration
UDP_HOST = "127.0.0.1"
UDP_PORT = 9999
MESSAGES_PER_THREAD = 500
THREADS_COUNT = 2
MESSAGE_RATE = 100  # messages per second per thread
PROJECT_DIR = Path(__file__).parent.parent
LOG_DIR = PROJECT_DIR  # Logs are created in project root when server runs from there
LOG_FILE = LOG_DIR / "unified_stream.log"
SERVER_BINARY = PROJECT_DIR / "UDPLogServer" / "udp_log_server"

# ANSI color codes for output
GREEN = '\033[92m'
RED = '\033[91m'
YELLOW = '\033[93m'
BLUE = '\033[94m'
RESET = '\033[0m'
CHECKMARK = f"{GREEN}✓{RESET}"
CROSS = f"{RED}✗{RESET}"

class UDPLogTester:
    def __init__(self):
        self.sock = None
        self.messages_sent = {}
        self.messages_lock = threading.Lock()
        self.start_time = None
        self.end_time = None
        
    def setup_socket(self):
        """Create and configure UDP socket"""
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 65536)
        
    def send_command(self, command):
        """Send a command to the UDP server"""
        message = f"CMD|{command}"
        self.sock.sendto(message.encode('utf-8'), (UDP_HOST, UDP_PORT))
        
    def send_message(self, source, message):
        """Send a log message to the UDP server"""
        formatted = f"{source}|{message}"
        self.sock.sendto(formatted.encode('utf-8'), (UDP_HOST, UDP_PORT))
        
    def worker_thread(self, thread_id):
        """Worker thread that sends messages at specified rate"""
        thread_name = f"THREAD_{thread_id}"
        interval = 1.0 / MESSAGE_RATE
        
        # Track messages for this thread
        self.messages_sent[thread_id] = []
        
        for i in range(MESSAGES_PER_THREAD):
            # Create traceable message with thread ID and sequence number
            message = f"Test message {thread_id:03d}-{i:05d} at {time.time():.6f}"
            
            # Send the message
            self.send_message(thread_name, message)
            
            # Track what we sent
            with self.messages_lock:
                self.messages_sent[thread_id].append((thread_id, i))
            
            # Rate limiting
            time.sleep(interval)
            
    def check_server_running(self):
        """Check if UDP log server is running"""
        print(f"\n{BLUE}1. Checking UDP log server...{RESET}")
        
        # First check if process is running
        try:
            result = subprocess.run(['pgrep', '-f', 'udp_log_server'], 
                                  capture_output=True, text=True)
            if not result.stdout.strip():
                print(f"   {CROSS} Server not running")
                print(f"   {YELLOW}Starting server...{RESET}")
                
                # Build if necessary
                if not SERVER_BINARY.exists():
                    print(f"   {YELLOW}Building server...{RESET}")
                    subprocess.run(['make', '-C', str(SERVER_BINARY.parent)], check=True)
                
                # Start server in background from project directory
                subprocess.Popen([str(SERVER_BINARY)], 
                               cwd=str(PROJECT_DIR),
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
                time.sleep(1)  # Give it time to start
                
                # Check again
                result = subprocess.run(['pgrep', '-f', 'udp_log_server'], 
                                      capture_output=True, text=True)
                if result.stdout.strip():
                    print(f"   {CHECKMARK} Server started successfully")
                else:
                    print(f"   {CROSS} Failed to start server")
                    return False
            else:
                print(f"   {CHECKMARK} Server is running (PID: {result.stdout.strip()})")
        except Exception as e:
            print(f"   {CROSS} Error checking server: {e}")
            return False
            
        # Test UDP connectivity
        try:
            test_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            test_sock.settimeout(0.5)
            test_sock.sendto(b"PING|Test", (UDP_HOST, UDP_PORT))
            test_sock.close()
            print(f"   {CHECKMARK} UDP port {UDP_PORT} is accessible")
            return True
        except Exception as e:
            print(f"   {CROSS} Cannot reach UDP port: {e}")
            return False
            
    def run_load_test(self):
        """Run the high-rate load test"""
        print(f"\n{BLUE}2. Running load test...{RESET}")
        
        # Setup socket
        self.setup_socket()
        
        # Start new session
        print(f"   Sending NEW_SESSION command...")
        self.send_command("NEW_SESSION")
        time.sleep(0.5)  # Let session initialize
        
        # Create and start worker threads
        threads = []
        print(f"   Starting {THREADS_COUNT} threads @ {MESSAGE_RATE} msg/sec each...")
        
        self.start_time = time.time()
        
        for i in range(THREADS_COUNT):
            t = threading.Thread(target=self.worker_thread, args=(i,))
            threads.append(t)
            t.start()
            
        # Wait for all threads to complete
        for t in threads:
            t.join()
            
        self.end_time = time.time()
        
        # Send end session
        time.sleep(0.5)  # Let last messages flush
        self.send_command("END_SESSION")
        
        # Calculate statistics
        total_sent = sum(len(msgs) for msgs in self.messages_sent.values())
        duration = self.end_time - self.start_time
        actual_rate = total_sent / duration
        expected_rate = THREADS_COUNT * MESSAGE_RATE
        
        print(f"   {CHECKMARK} Load test completed")
        print(f"   • Duration: {duration:.2f} seconds")
        print(f"   • Messages sent: {total_sent}")
        print(f"   • Target rate: {expected_rate:.0f} msg/sec")
        print(f"   • Actual rate: {actual_rate:.0f} msg/sec")
        
        # Rate check - be more forgiving due to Python sleep limitations
        rate_accuracy = (actual_rate / expected_rate) * 100
        if rate_accuracy >= 80:  # Accept 80% or higher due to system limitations
            print(f"   {CHECKMARK} Rate check passed ({rate_accuracy:.1f}% of target)")
            return True
        else:
            print(f"   {CROSS} Rate check failed ({rate_accuracy:.1f}% of target)")
            return False
            
    def verify_log_integrity(self):
        """Verify all messages were logged correctly"""
        print(f"\n{BLUE}3. Verifying log integrity...{RESET}")
        
        # Wait a bit for final writes
        time.sleep(1)
        
        # Find the most recent log file
        log_sessions_dir = LOG_DIR / "log_sessions"
        
        # First check if log_sessions directory exists, if not use unified_stream.log
        if not log_sessions_dir.exists():
            print(f"   {YELLOW}Log sessions directory not found, checking unified_stream.log{RESET}")
            if LOG_FILE.exists():
                latest_log = LOG_FILE
                print(f"   Using: {latest_log.name}")
            else:
                print(f"   {CROSS} No log file found")
                return False
        else:
            # Get most recent session file
            session_files = sorted(log_sessions_dir.glob("session_*.log"), 
                                  key=lambda x: x.stat().st_mtime)
            if not session_files:
                print(f"   {CROSS} No session files found")
                return False
                
            latest_log = session_files[-1]
            print(f"   Reading log: {latest_log.name}")
            
            # Also check symlink
            if LOG_FILE.exists() and LOG_FILE.is_symlink():
                print(f"   {CHECKMARK} Symlink exists: unified_stream.log -> {latest_log.name}")
        
        # Read and parse log file
        found_messages = {i: set() for i in range(THREADS_COUNT)}
        total_lines = 0
        
        try:
            with open(latest_log, 'r') as f:
                for line in f:
                    total_lines += 1
                    
                    # Skip header/footer lines
                    if '====' in line or 'Session' in line:
                        continue
                        
                    # Parse log line for our test messages
                    if 'THREAD_' in line and 'Test message' in line:
                        # Extract thread ID and sequence number
                        try:
                            # Find the test message pattern
                            import re
                            match = re.search(r'Test message (\d{3})-(\d{5})', line)
                            if match:
                                thread_id = int(match.group(1))
                                seq_num = int(match.group(2))
                                found_messages[thread_id].add(seq_num)
                        except:
                            pass
                            
        except Exception as e:
            print(f"   {CROSS} Error reading log file: {e}")
            return False
            
        # Check integrity
        print(f"   Total lines in log: {total_lines}")
        
        all_good = True
        for thread_id in range(THREADS_COUNT):
            expected = set(range(MESSAGES_PER_THREAD))
            found = found_messages[thread_id]
            missing = expected - found
            extra = found - expected
            
            if missing:
                print(f"   {CROSS} Thread {thread_id}: Missing {len(missing)} messages")
                if len(missing) <= 10:
                    print(f"       Missing sequences: {sorted(missing)[:10]}")
                all_good = False
            elif extra:
                print(f"   {CROSS} Thread {thread_id}: Found unexpected sequences")
                all_good = False
            else:
                print(f"   {CHECKMARK} Thread {thread_id}: All {MESSAGES_PER_THREAD} messages found")
                
        # Check for duplicates
        for thread_id in range(THREADS_COUNT):
            if len(found_messages[thread_id]) < len(self.messages_sent[thread_id]):
                dupe_count = len(self.messages_sent[thread_id]) - len(found_messages[thread_id])
                print(f"   {YELLOW}⚠ Thread {thread_id}: Possible duplicates or missing ({dupe_count}){RESET}")
                
        if all_good:
            print(f"   {CHECKMARK} Integrity check passed - all messages accounted for")
        else:
            print(f"   {CROSS} Integrity check failed - some messages missing or corrupted")
            
        return all_good
        
    def run_all_tests(self):
        """Run complete test suite"""
        print("=" * 60)
        print(f"{BLUE}UDP Logging System Test Suite{RESET}")
        print("=" * 60)
        
        results = {}
        
        # Test 1: Server check
        results['server'] = self.check_server_running()
        if not results['server']:
            print(f"\n{RED}Cannot proceed without server. Exiting.{RESET}")
            return False
            
        # Test 2: Load test
        results['load'] = self.run_load_test()
        
        # Test 3: Integrity check
        results['integrity'] = self.verify_log_integrity()
        
        # Summary
        print("\n" + "=" * 60)
        print(f"{BLUE}Test Summary:{RESET}")
        print("=" * 60)
        
        print(f"Server Check:    {CHECKMARK if results['server'] else CROSS}")
        print(f"Rate Check:      {CHECKMARK if results['load'] else CROSS}")
        print(f"Integrity Check: {CHECKMARK if results['integrity'] else CROSS}")
        
        all_passed = all(results.values())
        if all_passed:
            print(f"\n{GREEN}✓ ALL TESTS PASSED{RESET}")
        else:
            print(f"\n{RED}✗ SOME TESTS FAILED{RESET}")
            
        print("\nLatest log file:")
        print(f"  {BLUE}{LOG_FILE}{RESET}")
        
        return all_passed

def signal_handler(signum, frame):
    """Handle Ctrl+C gracefully"""
    print(f"\n{YELLOW}Test interrupted by user{RESET}")
    sys.exit(1)

def main():
    # Set up signal handler
    signal.signal(signal.SIGINT, signal_handler)
    
    # Run tests
    tester = UDPLogTester()
    success = tester.run_all_tests()
    
    # Exit with appropriate code
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()