/**
 * UDP Logger for JavaScript (Browser)
 * 
 * This file is a template that gets processed at build time
 * to inject the correct UDP log server IP address.
 * 
 * Since browsers can't send UDP directly, this sends HTTP POST
 * requests to a bridge endpoint that forwards to the UDP server.
 */

// Build-time configuration (will be replaced by build script)
const UDP_LOG_SERVER_CONFIG = {
    host: '172.20.10.9',  // Will be replaced with actual IP
    port: 8080,  // iOS app HTTP port
    udpPort: 9999,  // Actual UDP server port (for reference)
    buildTime: '2025-08-10 12:10:22',
    buildMachine: 'Jessicas-MacBook-Air'
};

class UDPLogger {
    constructor() {
        // Use build-time configured server IP
        this.logServerHost = UDP_LOG_SERVER_CONFIG.host;
        this.httpPort = UDP_LOG_SERVER_CONFIG.port;
        this.source = 'JS';
        this.connected = false;
        this.messageQueue = [];
        this.stats = {
            sent: 0,
            dropped: 0,
            bytes: 0,
            errors: 0
        };
        
        console.log(`[UDPLogger] Configured for server at ${this.logServerHost}:${this.httpPort}`);
        console.log(`[UDPLogger] Built on ${UDP_LOG_SERVER_CONFIG.buildTime} by ${UDP_LOG_SERVER_CONFIG.buildMachine}`);
        
        // Try to determine if we're in a browser or native context
        this.isBrowser = typeof window !== 'undefined';
        
        // For iOS app's built-in web view, use message passing
        if (this.isBrowser && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.logging) {
            this.useWebKit = true;
            this.connect();
        } else {
            // For external browsers, send to iOS device which will forward to UDP server
            this.useHTTP = true;
            // Get the iOS device IP from the current page URL
            if (window.location.hostname) {
                this.iosDeviceHost = window.location.hostname;
            } else {
                this.iosDeviceHost = this.logServerHost; // Fallback
            }
            this.connect();
        }
    }
    
    connect() {
        if (this.useWebKit) {
            // Send via WebKit message handler
            this.connected = true;
            this.log('==== JavaScript Client Connected (WebKit) ====');
        } else if (this.useHTTP) {
            // Use HTTP endpoint on iOS device
            this.connected = true;
            this.log(`==== JavaScript Client Connected (HTTP to ${this.iosDeviceHost}) ====`);
            
            // Send a special message to the UDP server to indicate client connected
            this.sendDirectToUDP('CLIENT', '==== Browser Client Connected ====');
        }
        
        // Process any queued messages
        this.flushQueue();
    }
    
    disconnect() {
        if (this.connected) {
            this.log('==== JavaScript Client Disconnected ====');
            this.connected = false;
        }
    }
    
    log(message) {
        this.logWithSource(this.source, message);
    }
    
    logWithSource(source, message) {
        if (!message) return;
        
        const formattedMessage = `${source}|${message}`;
        
        if (!this.connected) {
            this.messageQueue.push(formattedMessage);
            if (this.messageQueue.length > 1000) {
                // Prevent memory leak
                this.messageQueue.shift();
                this.stats.dropped++;
            }
            return;
        }
        
        this.sendMessage(formattedMessage);
    }
    
    sendMessage(message) {
        if (this.useWebKit) {
            // Send via WebKit bridge to iOS app
            try {
                window.webkit.messageHandlers.logging.postMessage({
                    type: 'udp_log',
                    message: message
                });
                this.stats.sent++;
                this.stats.bytes += message.length;
            } catch (e) {
                console.error('Failed to send via WebKit:', e);
                this.stats.dropped++;
            }
        } else if (this.useHTTP) {
            // Send via HTTP to iOS app's logging endpoint
            // The iOS app will forward this to the UDP server
            const url = `http://${this.iosDeviceHost}:${this.httpPort}/log`;
            
            // Use fetch with keepalive for reliability
            fetch(url, {
                method: 'POST',
                headers: {
                    'Content-Type': 'text/plain'
                },
                body: message,
                mode: 'cors',
                keepalive: true
            }).then(() => {
                this.stats.sent++;
                this.stats.bytes += message.length;
            }).catch((error) => {
                console.warn(`Log send failed to ${url}:`, error.message);
                this.stats.errors++;
                
                // Try direct UDP server connection as fallback
                this.sendDirectToUDP(message.split('|')[0], message.split('|').slice(1).join('|'));
            });
        }
    }
    
    // Attempt to send directly to UDP log server via HTTP bridge
    sendDirectToUDP(source, message) {
        // Try to send directly to the Mac's UDP logger HTTP bridge
        // This assumes the Mac is running an HTTP-to-UDP bridge
        const bridgeUrl = `http://${this.logServerHost}:8081/udp-bridge`;
        const formattedMessage = `${source}|${message}`;
        
        fetch(bridgeUrl, {
            method: 'POST',
            body: formattedMessage,
            mode: 'no-cors', // Avoid CORS issues
            keepalive: true
        }).catch(() => {
            // Silently fail - this is best effort
            this.stats.dropped++;
        });
    }
    
    flushQueue() {
        while (this.messageQueue.length > 0 && this.connected) {
            const message = this.messageQueue.shift();
            this.sendMessage(message);
        }
    }
    
    // HLS-specific logging helpers
    logHLS(message) {
        this.logWithSource('JS-HLS', message);
    }
    
    logPlayback(message) {
        this.logWithSource('JS-PLAY', message);
    }
    
    logError(message) {
        this.logWithSource('JS-ERR', message);
    }
    
    logNetwork(message) {
        this.logWithSource('JS-NET', message);
    }
    
    logQoE(metrics) {
        this.logWithSource('JS-QoE', JSON.stringify(metrics));
    }
    
    // Get statistics
    getStats() {
        return {
            ...this.stats,
            queued: this.messageQueue.length,
            serverIP: this.logServerHost,
            iosDeviceIP: this.iosDeviceHost || 'N/A'
        };
    }
}

// Auto-initialize and attach HLS.js event listeners if available
let udpLogger = null;

if (typeof window !== 'undefined') {
    // Initialize logger
    udpLogger = new UDPLogger();
    
    // Make it globally available
    window.udpLogger = udpLogger;
    
    // Log page load
    udpLogger.log(`Page loaded: ${window.location.href}`);
    
    // Hook into HLS.js when it becomes available
    function hookHLS() {
        if (!window.Hls || !window.Hls.Events) {
            // HLS.js not ready yet, try again later
            setTimeout(hookHLS, 100);
            return;
        }
        
        udpLogger.log('HLS.js detected, hooking into events');
        const originalHlsConstructor = window.Hls;
        window.Hls = function(...args) {
            const instance = new originalHlsConstructor(...args);
            
            // Attach event listeners for logging
            instance.on(originalHlsConstructor.Events.MANIFEST_LOADED, (event, data) => {
                udpLogger.logHLS(`Manifest loaded: ${data.levels.length} levels`);
            });
            
            instance.on(originalHlsConstructor.Events.LEVEL_LOADED, (event, data) => {
                udpLogger.logHLS(`Level ${data.level} loaded: ${data.details.fragments.length} fragments`);
            });
            
            instance.on(originalHlsConstructor.Events.FRAG_LOADED, (event, data) => {
                udpLogger.logHLS(`Fragment loaded: ${data.frag.sn} (${data.frag.type})`);
            });
            
            instance.on(originalHlsConstructor.Events.ERROR, (event, data) => {
                udpLogger.logError(`HLS Error: ${data.type} - ${data.details}`);
            });
            
            instance.on(originalHlsConstructor.Events.MEDIA_ATTACHED, (event, data) => {
                udpLogger.logPlayback('Media attached to video element');
            });
            
            instance.on(originalHlsConstructor.Events.BUFFER_APPENDED, (event, data) => {
                udpLogger.logHLS(`Buffer appended: ${data.type}`);
            });
            
            return instance;
        };
        
        // Copy static properties
        Object.keys(originalHlsConstructor).forEach(key => {
            window.Hls[key] = originalHlsConstructor[key];
        });
    }
    
    // Start trying to hook HLS.js
    hookHLS();
    
    // Hook into video element events
    document.addEventListener('DOMContentLoaded', () => {
        const videos = document.querySelectorAll('video');
        videos.forEach(video => {
            video.addEventListener('play', () => udpLogger.logPlayback('Video play'));
            video.addEventListener('pause', () => udpLogger.logPlayback('Video pause'));
            video.addEventListener('waiting', () => udpLogger.logPlayback('Video buffering'));
            video.addEventListener('playing', () => udpLogger.logPlayback('Video playing'));
            video.addEventListener('error', (e) => udpLogger.logError(`Video error: ${e.message}`));
            video.addEventListener('loadedmetadata', () => {
                udpLogger.logPlayback(`Video metadata loaded: ${video.videoWidth}x${video.videoHeight}`);
            });
        });
    });
    
    // Log unhandled errors
    window.addEventListener('error', (event) => {
        udpLogger.logError(`Unhandled error: ${event.message} at ${event.filename}:${event.lineno}`);
    });
    
    // Log when page unloads
    window.addEventListener('beforeunload', () => {
        udpLogger.log('Page unloading');
        udpLogger.disconnect();
    });
}