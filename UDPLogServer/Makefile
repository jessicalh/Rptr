# Makefile for UDP Log Server

CXX = clang++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra -pthread
TARGET = udp_log_server
SOURCE = udp_log_server.cpp

# Default target
all: $(TARGET)

# Build the server
$(TARGET): $(SOURCE)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(SOURCE)

# Run the server
run: $(TARGET)
	./$(TARGET)

# Clean build artifacts and log file
clean:
	rm -f $(TARGET) unified_stream.log

# Install (optional - copies to /usr/local/bin)
install: $(TARGET)
	sudo cp $(TARGET) /usr/local/bin/

.PHONY: all run clean install