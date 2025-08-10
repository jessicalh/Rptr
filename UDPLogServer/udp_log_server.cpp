/**
 * UDP Log Server with Session Management
 * 
 * A high-performance UDP logging server that accepts log messages
 * from multiple clients (iOS app and JavaScript) and writes them to a 
 * unified log file with timestamps and source identification.
 * 
 * Features:
 * - Thread-safe concurrent logging
 * - Session management with GUIDs
 * - Special commands for new/end session
 * - Automatic file rotation
 * - Minimal latency UDP protocol
 * - Source identification (iOS/JS)
 * - Microsecond precision timestamps
 * 
 * Special Commands:
 * - "CMD|NEW_SESSION" - Start new session with new GUID and file
 * - "CMD|END_SESSION" - End current session
 */

#include <iostream>
#include <fstream>
#include <string>
#include <thread>
#include <mutex>
#include <queue>
#include <condition_variable>
#include <atomic>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <cstring>
#include <random>
#include <filesystem>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <signal.h>

constexpr int UDP_PORT = 9999;
constexpr int BUFFER_SIZE = 4096;
constexpr const char* LOG_DIR = "/Users/jessicahansberry/projects/Rptr/logs";
constexpr const char* CURRENT_LOG = "/Users/jessicahansberry/projects/Rptr/logs/current.log";
constexpr const char* SERVER_LOG = "/Users/jessicahansberry/projects/Rptr/logs/server.log";

class UDPLogServer {
private:
    // Server state
    std::atomic<bool> running{false};
    std::atomic<bool> session_active{false};
    int socket_fd{-1};
    
    // Session management
    std::string session_guid;
    std::string current_log_file;
    std::mutex session_mutex;
    
    // File handling
    std::ofstream log_file;
    std::mutex file_mutex;
    
    // Message queue for async writing
    std::queue<std::string> message_queue;
    std::mutex queue_mutex;
    std::condition_variable queue_cv;
    
    // Threads
    std::thread receiver_thread;
    std::thread writer_thread;
    
    // Statistics
    std::atomic<uint64_t> messages_received{0};
    std::atomic<uint64_t> bytes_received{0};
    std::atomic<uint64_t> sessions_created{0};
    
private:
    // Server log for tracking server events
    std::ofstream server_log;
    std::ofstream current_log_file_stream;
    
    void log_server_event(const std::string& event) {
        auto now = std::chrono::system_clock::now();
        auto time_t = std::chrono::system_clock::to_time_t(now);
        
        if (!server_log.is_open()) {
            server_log.open(SERVER_LOG, std::ios::out | std::ios::app);
        }
        
        server_log << std::put_time(std::localtime(&time_t), "%Y-%m-%d %H:%M:%S") 
                   << " | " << event << std::endl;
        server_log.flush();
    }
    
public:
    UDPLogServer() {
        // Create log directory if it doesn't exist
        std::filesystem::create_directories(LOG_DIR);
        
        // Open server log
        server_log.open(SERVER_LOG, std::ios::out | std::ios::app);
        log_server_event("Server instance created");
        
        // Open current.log for immediate writing
        current_log_file_stream.open(CURRENT_LOG, std::ios::out | std::ios::trunc);
        current_log_file_stream << "=== UDP Log Server Started ===" << std::endl;
        current_log_file_stream << "Timestamp: " << get_timestamp() << std::endl;
        current_log_file_stream << "Waiting for messages on port " << UDP_PORT << std::endl;
        current_log_file_stream << "==============================" << std::endl;
        current_log_file_stream.flush();
    }
    
    ~UDPLogServer() {
        log_server_event("Server instance destroyed");
        if (server_log.is_open()) {
            server_log.close();
        }
        if (current_log_file_stream.is_open()) {
            current_log_file_stream.close();
        }
        stop();
    }
    
    bool start() {
        // Create UDP socket
        socket_fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (socket_fd < 0) {
            std::cerr << "Failed to create socket: " << strerror(errno) << std::endl;
            return false;
        }
        
        // Allow socket reuse
        int reuse = 1;
        if (setsockopt(socket_fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse)) < 0) {
            std::cerr << "Failed to set SO_REUSEADDR: " << strerror(errno) << std::endl;
            close(socket_fd);
            return false;
        }
        
        // Bind to port
        struct sockaddr_in server_addr{};
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = INADDR_ANY;
        server_addr.sin_port = htons(UDP_PORT);
        
        if (bind(socket_fd, (struct sockaddr*)&server_addr, sizeof(server_addr)) < 0) {
            std::cerr << "Failed to bind to port " << UDP_PORT << ": " << strerror(errno) << std::endl;
            close(socket_fd);
            return false;
        }
        
        // Set receive timeout to allow periodic checking of running flag
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = 100000; // 100ms timeout
        setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        
        running = true;
        
        // Start worker threads
        receiver_thread = std::thread(&UDPLogServer::receive_loop, this);
        writer_thread = std::thread(&UDPLogServer::write_loop, this);
        
        std::cout << "UDP Log Server started on port " << UDP_PORT << std::endl;
        std::cout << "Log directory: " << LOG_DIR << std::endl;
        std::cout << "Waiting for NEW_SESSION command..." << std::endl;
        std::cout << "Press Ctrl+C to stop server" << std::endl;
        
        return true;
    }
    
    void stop() {
        if (!running) return;
        
        std::cout << "\nStopping server..." << std::endl;
        running = false;
        
        // End any active session
        if (session_active) {
            end_session();
        }
        
        // Wake up writer thread
        queue_cv.notify_all();
        
        // Wait for threads to finish
        if (receiver_thread.joinable()) {
            receiver_thread.join();
        }
        if (writer_thread.joinable()) {
            writer_thread.join();
        }
        
        // Close socket
        if (socket_fd >= 0) {
            close(socket_fd);
            socket_fd = -1;
        }
        
        std::cout << "Server stopped. Statistics:" << std::endl;
        std::cout << "  Total sessions: " << sessions_created << std::endl;
        std::cout << "  Messages received: " << messages_received << std::endl;
        std::cout << "  Bytes received: " << bytes_received << std::endl;
    }
    
    bool is_running() const {
        return running;
    }
    
private:
    std::string generate_guid() {
        std::random_device rd;
        std::mt19937 gen(rd());
        std::uniform_int_distribution<> dis(0, 15);
        
        const char* hex_chars = "0123456789abcdef";
        std::string guid;
        
        for (int i = 0; i < 32; i++) {
            if (i == 8 || i == 12 || i == 16 || i == 20) {
                guid += '-';
            }
            guid += hex_chars[dis(gen)];
        }
        
        return guid;
    }
    
    void start_new_session() {
        std::lock_guard<std::mutex> lock(session_mutex);
        
        // End current session if active
        if (session_active) {
            end_session_internal();
        }
        
        // Generate new GUID
        session_guid = generate_guid();
        sessions_created++;
        
        // Create new log file
        auto now = std::chrono::system_clock::now();
        auto time_t = std::chrono::system_clock::to_time_t(now);
        struct tm* tm_info = std::localtime(&time_t);
        
        std::ostringstream filename;
        filename << LOG_DIR << "/session_";
        filename << std::put_time(tm_info, "%Y%m%d_%H%M%S");
        filename << "_" << session_guid.substr(0, 8) << ".log";
        
        current_log_file = filename.str();
        
        // Delete old session file if requested
        if (std::filesystem::exists("unified_stream.log")) {
            std::filesystem::remove("unified_stream.log");
        }
        
        // Create symlink to current session for convenience
        std::filesystem::remove("unified_stream.log");
        std::filesystem::create_symlink(current_log_file, "unified_stream.log");
        
        // Open new log file
        {
            std::lock_guard<std::mutex> file_lock(file_mutex);
            if (log_file.is_open()) {
                log_file.close();
            }
            log_file.open(current_log_file, std::ios::out | std::ios::trunc);
            
            // Write header
            log_file << "========================================" << std::endl;
            log_file << "UDP Log Session Started" << std::endl;
            log_file << "Session ID: " << session_guid << std::endl;
            log_file << "Time: " << std::put_time(tm_info, "%Y-%m-%d %H:%M:%S") << std::endl;
            log_file << "Port: " << UDP_PORT << std::endl;
            log_file << "========================================" << std::endl;
            log_file << std::endl;
            log_file.flush();
        }
        
        session_active = true;
        
        std::cout << "\n=== NEW SESSION STARTED ===" << std::endl;
        std::cout << "Session ID: " << session_guid << std::endl;
        std::cout << "Log file: " << current_log_file << std::endl;
        std::cout << "Symlink: unified_stream.log" << std::endl;
        std::cout << std::endl;
    }
    
    void end_session() {
        std::lock_guard<std::mutex> lock(session_mutex);
        end_session_internal();
    }
    
    void end_session_internal() {
        if (!session_active) return;
        
        {
            std::lock_guard<std::mutex> file_lock(file_mutex);
            
            if (log_file.is_open()) {
                auto now = std::chrono::system_clock::now();
                auto time_t = std::chrono::system_clock::to_time_t(now);
                
                log_file << std::endl;
                log_file << "========================================" << std::endl;
                log_file << "Session Ended" << std::endl;
                log_file << "Session ID: " << session_guid << std::endl;
                log_file << "Time: " << std::put_time(std::localtime(&time_t), "%Y-%m-%d %H:%M:%S") << std::endl;
                log_file << "Messages: " << messages_received << std::endl;
                log_file << "========================================" << std::endl;
                log_file.flush();
                log_file.close();
            }
        }
        
        session_active = false;
        
        std::cout << "\n=== SESSION ENDED ===" << std::endl;
        std::cout << "Session ID: " << session_guid << std::endl;
        std::cout << "Log file: " << current_log_file << std::endl;
        std::cout << std::endl;
        
        session_guid.clear();
        current_log_file.clear();
        
        // Reset message counter for new session
        messages_received = 0;
        bytes_received = 0;
    }
    
    std::string get_timestamp() {
        auto now = std::chrono::system_clock::now();
        auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
            now.time_since_epoch()).count();
        
        auto microseconds = micros % 1000000;
        
        auto time_t = std::chrono::system_clock::to_time_t(now);
        struct tm* tm_info = std::localtime(&time_t);
        
        std::ostringstream oss;
        oss << std::put_time(tm_info, "%H:%M:%S");
        oss << '.' << std::setfill('0') << std::setw(6) << microseconds;
        
        return oss.str();
    }
    
    void receive_loop() {
        char buffer[BUFFER_SIZE];
        struct sockaddr_in client_addr{};
        socklen_t client_len = sizeof(client_addr);
        
        while (running) {
            // Receive UDP packet
            ssize_t bytes = recvfrom(socket_fd, buffer, BUFFER_SIZE - 1, 0,
                                    (struct sockaddr*)&client_addr, &client_len);
            
            if (bytes < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Timeout - check if still running
                    continue;
                }
                std::cerr << "Receive error: " << strerror(errno) << std::endl;
                continue;
            }
            
            if (bytes == 0) continue;
            
            // Null terminate
            buffer[bytes] = '\0';
            
            // Parse message format: "SOURCE|MESSAGE"
            std::string message(buffer);
            std::string source = "UNKNOWN";
            std::string content = message;
            
            size_t delimiter_pos = message.find('|');
            if (delimiter_pos != std::string::npos) {
                source = message.substr(0, delimiter_pos);
                content = message.substr(delimiter_pos + 1);
            }
            
            // Handle special commands
            if (source == "CMD") {
                if (content == "NEW_SESSION") {
                    start_new_session();
                    continue;
                } else if (content == "END_SESSION") {
                    end_session();
                    continue;
                }
            }
            
            // Update statistics (always count messages)
            messages_received++;
            bytes_received += bytes;
            
            // Get client IP
            char client_ip[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &client_addr.sin_addr, client_ip, INET_ADDRSTRLEN);
            
            // Format log line
            std::ostringstream log_line;
            log_line << get_timestamp() 
                    << " [" << std::left << std::setw(6) << source << "]"
                    << " [" << client_ip << "]"
                    << " " << content;
            
            // Queue for writing
            {
                std::lock_guard<std::mutex> lock(queue_mutex);
                message_queue.push(log_line.str());
            }
            queue_cv.notify_one();
        }
    }
    
    void write_loop() {
        while (running || !message_queue.empty()) {
            std::unique_lock<std::mutex> lock(queue_mutex);
            
            // Wait for messages or shutdown
            queue_cv.wait(lock, [this] {
                return !message_queue.empty() || !running;
            });
            
            // Process all queued messages
            while (!message_queue.empty()) {
                std::string message = message_queue.front();
                message_queue.pop();
                lock.unlock();
                
                // ALWAYS write to current.log (recreate if missing)
                {
                    std::lock_guard<std::mutex> file_lock(file_mutex);
                    
                    // Check if file exists, if not reopen
                    if (!std::filesystem::exists(CURRENT_LOG)) {
                        current_log_file_stream.close();
                        current_log_file_stream.clear(); // Clear any error flags
                        current_log_file_stream.open(CURRENT_LOG, std::ios::out | std::ios::app);
                        if (current_log_file_stream.is_open()) {
                            current_log_file_stream << "=== Log File Created ===" << std::endl;
                            current_log_file_stream << "Timestamp: " << get_timestamp() << std::endl;
                            current_log_file_stream << "===================" << std::endl;
                        }
                    }
                    
                    // Check if stream is good
                    if (!current_log_file_stream.is_open() || !current_log_file_stream.good()) {
                        current_log_file_stream.close();
                        current_log_file_stream.clear(); // Clear any error flags
                        current_log_file_stream.open(CURRENT_LOG, std::ios::out | std::ios::app);
                    }
                    
                    if (current_log_file_stream.is_open()) {
                        current_log_file_stream << message << std::endl;
                        current_log_file_stream.flush();  // Always flush for immediate visibility
                    } else {
                        std::cerr << "ERROR: Cannot write to log file: " << message << std::endl;
                    }
                }
                
                // Also write to session file if session is active
                if (session_active) {
                    std::lock_guard<std::mutex> file_lock(file_mutex);
                    if (log_file.is_open()) {
                        log_file << message << std::endl;
                        
                        // Flush periodically for real-time viewing
                        if (messages_received % 10 == 0) {
                            log_file.flush();
                        }
                    }
                }
                
                lock.lock();
            }
        }
        
        // Final flush
        if (session_active) {
            std::lock_guard<std::mutex> file_lock(file_mutex);
            if (log_file.is_open()) {
                log_file.flush();
            }
        }
    }
};

// Global server instance for signal handling
UDPLogServer* g_server = nullptr;

void signal_handler(int signal) {
    if (signal == SIGINT || signal == SIGTERM) {
        if (g_server && g_server->is_running()) {
            g_server->stop();
        }
        exit(0);
    }
}

int main(int argc, char* argv[]) {
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    signal(SIGPIPE, SIG_IGN); // Ignore broken pipe
    
    // Create and start server
    UDPLogServer server;
    g_server = &server;
    
    if (!server.start()) {
        std::cerr << "Failed to start server" << std::endl;
        return 1;
    }
    
    // Keep main thread alive
    while (server.is_running()) {
        std::this_thread::sleep_for(std::chrono::seconds(1));
    }
    
    return 0;
}