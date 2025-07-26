// Get elements
var video = document.getElementById('video');
var status = document.getElementById('status');
var stats = document.getElementById('stats');
var connectionStatus = document.getElementById('connectionStatus');
var recordingInfo = document.getElementById('recordingInfo');
var recordBtn = document.getElementById('recordBtn');
var downloadBtn = document.getElementById('downloadBtn');

// Get configuration from injected values
var videoSrc = window.location.origin + window.APP_CONFIG.streamUrl;
var locationEndpoint = window.location.origin + window.APP_CONFIG.locationEndpoint;

// Debug logging to track URL usage
console.log('DEBUG: APP_CONFIG.streamUrl =', window.APP_CONFIG.streamUrl);
console.log('DEBUG: Computed videoSrc =', videoSrc);
console.log('DEBUG: locationEndpoint =', locationEndpoint);

// State variables
var hls = null;
var mediaRecorder = null;
var recordedChunks = [];
var isRecording = false;
var reconnectTimer = null;
var statsInterval = null;
var lastSegmentTime = 0;
var connectionCheckInterval = null;
var hasConnectedOnce = false;
var map = null;
var deviceMarker = null;
var statusWorker = null;

function initializeMap() {
  if (map) return;
  
  fetch(locationEndpoint)
    .then(response => response.json())
    .then(data => {
      if (data.latitude && data.longitude) {
        map = L.map('mapContainer').setView([data.latitude, data.longitude], 15);
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
          attribution: '© OpenStreetMap contributors'
        }).addTo(map);
        
        deviceMarker = L.marker([data.latitude, data.longitude])
          .addTo(map)
          .bindPopup('Device Location<br>Accuracy: ' + data.accuracy + 'm');
      } else {
        document.getElementById('mapContainer').innerHTML = '<div style="text-align: center; padding: 50px; color: #666;">Location not available</div>';
      }
    })
    .catch(error => {
      console.error('Error fetching location:', error);
      document.getElementById('mapContainer').innerHTML = '<div style="text-align: center; padding: 50px; color: #666;">Could not load location</div>';
    });
}

function setConnectionStatus(state) {
  connectionStatus.className = 'connection-indicator ' + state;
  status.className = 'status ' + state;
}

function initHLS() {
  if (hls) {
    hls.destroy();
  }
  
  if (!Hls.isSupported()) {
    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = videoSrc;
      status.innerHTML = 'Using native HLS support';
      setConnectionStatus('');
    } else {
      status.innerHTML = 'HLS not supported in this browser';
      setConnectionStatus('error');
    }
    return;
  }
  
  hls = new Hls({
    debug: false, // Disable debug for production
    enableWorker: true,
    lowLatencyMode: false, // Disable aggressive low latency
    liveBackBufferLength: 18, // Keep 18 seconds of back buffer (6 segments)
    liveSyncDurationCount: 3, // Stay 3 segments (9 seconds) from edge
    liveMaxLatencyDurationCount: 6, // Allow up to 6 segments latency (18 seconds)
    maxBufferLength: 30, // Buffer up to 30 seconds (10 segments)
    maxMaxBufferLength: 60, // Allow up to 1 minute
    maxBufferSize: 60 * 1024 * 1024, // 60 MB buffer size
    maxBufferHole: 0.5, // More tolerant of gaps
    highBufferWatchdogPeriod: 3,
    nudgeOffset: 0.5, // Less aggressive nudging
    nudgeMaxRetry: 5,
    maxFragLookUpTolerance: 0.5,
    liveDurationInfinity: true,
    startLevel: -1,
    fragLoadingTimeOut: 20000, // Longer timeout for fragments
    fragLoadingMaxRetry: 10,
    fragLoadingRetryDelay: 1000,
    manifestLoadingTimeOut: 10000,
    manifestLoadingMaxRetry: 5,
    manifestLoadingRetryDelay: 1000,
    // Additional settings to prevent stalling
    initialLiveManifestSize: 2, // Wait for 2 segments before starting
    stretchShortVideoTrack: true,
    forceKeyFrameOnDiscontinuity: true,
    // Stall detection settings
    stallDebounceMs: 1000,
    jumpThreshold: 0.5
  });
  
  setConnectionStatus('connecting');
  status.innerHTML = 'Connecting to stream...';
  
  console.log('DEBUG: About to load HLS source:', videoSrc);
  hls.loadSource(videoSrc);
  hls.attachMedia(video);
  
  hls.on(Hls.Events.MANIFEST_PARSED, function() {
    hasConnectedOnce = true;
    status.innerHTML = 'Stream connected - Starting playback';
    setConnectionStatus('');
    
    // Check if this is a live stream
    if (hls.levels && hls.levels.length > 0) {
      var level = hls.levels[0];
      if (level.details && level.details.live) {
        console.log('Live stream detected');
        // For live streams, set to live edge
        hls.config.liveSyncDuration = 3;
        hls.config.liveMaxLatencyDuration = 10;
        hls.liveSyncPosition = hls.liveSyncPosition || 0;
      }
    }
    
    video.play().catch(function(e) {
      console.log('Autoplay prevented:', e);
      // Remove muted attribute after first user interaction
      document.addEventListener('click', function() {
        video.muted = false;
      }, { once: true });
    });
  });
  
  video.addEventListener('playing', function() {
    status.innerHTML = 'Live Broadcast';
    setConnectionStatus('');
    
    // Hide duration display for live streams
    if (video.duration === Infinity || isNaN(video.duration)) {
      // This is a live stream
      var controls = video.controls;
      if (controls) {
        // Keep seeking to near-live edge periodically
        setInterval(function() {
          if (!video.paused && video.duration > 0 && isFinite(video.duration)) {
            var liveEdge = video.duration;
            var currentTime = video.currentTime;
            if (liveEdge - currentTime > 10) {
              // We're too far behind, seek closer to live
              video.currentTime = liveEdge - 5;
            }
          }
        }, 5000);
      }
    }
  });
  
  hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
    lastSegmentTime = Date.now();
  });
  
  // Check for live stream on level loaded
  hls.on(Hls.Events.LEVEL_LOADED, function(event, data) {
    if (data.details.live) {
      console.log('Live stream confirmed - hiding duration display');
      // Try to hide duration in controls if possible
      video.style.setProperty('--duration-display', 'none');
      
      // Ensure we stay at live edge
      if (!video.paused) {
        var targetLatency = data.details.targetduration * 3;
        var currentLatency = data.details.totalduration - video.currentTime;
        if (currentLatency > targetLatency) {
          console.log('Seeking to live edge');
          video.currentTime = data.details.totalduration - targetLatency;
        }
      }
    }
  });
  
  hls.on(Hls.Events.ERROR, function (event, data) {
    console.log('HLS error:', data.type, data.details, 'Fatal:', data.fatal);
    
    // Check for 410 Gone error which indicates URL was regenerated
    if (data.type === Hls.ErrorTypes.NETWORK_ERROR && data.response && data.response.code === 410) {
      console.log('URL has been regenerated (410 Gone) - reloading page...');
      status.innerHTML = 'Stream URL changed - Reloading...';
      setConnectionStatus('error');
      // Reload the page after a short delay
      setTimeout(function() {
        window.location.reload();
      }, 1000);
      return;
    }
    
    if (data.fatal) {
      status.innerHTML = 'Connection lost - Reconnecting...';
      setConnectionStatus('error');
      scheduleReconnect();
    } else {
      // Non-fatal errors, try to recover
      if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
        hls.startLoad();
      } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
        hls.recoverMediaError();
      }
    }
  });
}

function scheduleReconnect() {
  if (!reconnectTimer) {
    reconnectTimer = setTimeout(function() {
      console.log('Attempting to reconnect...');
      setConnectionStatus('connecting');
      status.innerHTML = 'Reconnecting...';
      initHLS();
      reconnectTimer = null;
    }, 1000);
  }
}

function startConnectionMonitor() {
  if (connectionCheckInterval) {
    clearInterval(connectionCheckInterval);
  }
  
  connectionCheckInterval = setInterval(function() {
    // Check if we've received data recently
    if (Date.now() - lastSegmentTime > 5000 && hasConnectedOnce) {
      console.log('No data received for 5 seconds, reconnecting...');
      scheduleReconnect();
    }
  }, 2000);
}

function updateStats() {
  if (!hls || !hls.media) return;
  
  var buffered = hls.media.buffered;
  var bufferLen = buffered.length ? (buffered.end(buffered.length-1) - hls.media.currentTime).toFixed(3) : '0.000';
  var currentTime = hls.media.currentTime.toFixed(2);
  var level = hls.currentLevel >= 0 ? hls.levels[hls.currentLevel] : null;
  var bitrate = level ? Math.round(level.bitrate / 1000) + 'kbps' : '--';
  
  // Estimate latency based on segment timing
  var estimatedLatency = lastSegmentTime > 0 ? ((Date.now() - lastSegmentTime) / 1000).toFixed(3) + 's' : '--';
  
  stats.innerHTML = 'Latency: ~' + estimatedLatency + ' | Buffer: ' + bufferLen + 's | Bitrate: ' + bitrate + ' | Time: ' + currentTime + 's';
}

function toggleRecording() {
  if (!isRecording) {
    startRecording();
  } else {
    stopRecording();
  }
}

function startRecording() {
  if (!video.captureStream) {
    recordingInfo.innerHTML = 'Recording not supported in this browser';
    return;
  }
  
  recordedChunks = [];
  var stream = video.captureStream(30);
  
  try {
    mediaRecorder = new MediaRecorder(stream, {
      mimeType: 'video/webm; codecs=vp9'
    });
  } catch (e) {
    try {
      mediaRecorder = new MediaRecorder(stream, {
        mimeType: 'video/webm'
      });
    } catch (e2) {
      recordingInfo.innerHTML = 'Recording failed: ' + e2.message;
      return;
    }
  }
  
  mediaRecorder.ondataavailable = function(event) {
    if (event.data && event.data.size > 0) {
      recordedChunks.push(event.data);
    }
  };
  
  mediaRecorder.onstop = function() {
    var blob = new Blob(recordedChunks, { type: 'video/webm' });
    var url = URL.createObjectURL(blob);
    downloadBtn.href = url;
    downloadBtn.download = 'stream_' + Date.now() + '.webm';
    downloadBtn.style.display = 'inline-block';
    recordingInfo.innerHTML = 'Recording saved (' + (blob.size / 1048576).toFixed(2) + ' MB)';
  };
  
  mediaRecorder.start(1000);
  isRecording = true;
  recordBtn.textContent = 'Stop Recording';
  recordBtn.classList.add('recording');
  recordingInfo.innerHTML = 'Recording in progress...';
}

function stopRecording() {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    mediaRecorder.stop();
    isRecording = false;
    recordBtn.textContent = 'Start Recording';
    recordBtn.classList.remove('recording');
  }
}

function toggleDebug() {
  debugMode = document.getElementById('debugToggle').checked;
  var stats = document.getElementById('stats');
  if (debugMode) {
    stats.style.display = 'block';
  } else {
    stats.style.display = 'none';
  }
}

// Mobile detection
var isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
if (isMobile) {
  document.body.classList.add('mobile-device');
}

// Debug mode toggle - ENABLED BY DEFAULT FOR DEBUGGING
var debugMode = true;
document.addEventListener('keydown', function(e) {
  if (e.key === 'd' && e.ctrlKey) {
    e.preventDefault();
    debugMode = !debugMode;
    document.body.classList.toggle('debug-active', debugMode);
    console.log('Debug mode:', debugMode ? 'ON' : 'OFF');
  }
});

// Enable debug mode on page load
document.addEventListener('DOMContentLoaded', function() {
  document.body.classList.add('debug-active');
  console.log('Debug mode enabled by default');
});

// Touch gesture for debug mode on mobile
var touchCount = 0;
var touchTimer = null;
document.addEventListener('touchend', function(e) {
  if (e.target.closest('.title-bar')) {
    touchCount++;
    if (touchCount === 3) {
      debugMode = !debugMode;
      document.body.classList.toggle('debug-active', debugMode);
      touchCount = 0;
    }
    clearTimeout(touchTimer);
    touchTimer = setTimeout(function() {
      touchCount = 0;
    }, 1000);
  }
});

// AbortController for cancelling in-flight requests
var statusAbortController = null;

// Status polling function with optimizations
function updateStatus() {
  // Cancel any in-flight request
  if (statusAbortController) {
    statusAbortController.abort();
  }
  
  // Create new abort controller for this request
  statusAbortController = new AbortController();
  
  var requestUrl = window.location.origin + '/status';
  console.log('Status poll: Requesting', requestUrl);
  
  // Use fetch with optimizations to prevent video interference
  fetch(requestUrl, {
    method: 'GET',
    signal: statusAbortController.signal,
    // Use keepalive to allow request to continue in background
    keepalive: true,
    // Set priority to low to avoid interfering with video
    priority: 'low',
    // Cache control to prevent caching status
    cache: 'no-store',
    // Add timeout
    signal: AbortSignal.timeout ? AbortSignal.timeout(5000) : statusAbortController.signal
  })
    .then(response => {
      console.log('Status poll: Response received', response.status, response.statusText);
      if (!response.ok) {
        throw new Error('Response not ok: ' + response.status);
      }
      return response.json();
    })
    .then(data => {
      console.log('Status poll: Data received', JSON.stringify(data));
      
      // Use requestAnimationFrame to update UI without blocking video
      requestAnimationFrame(function() {
        // Update title if changed
        if (data.title) {
          var titleElement = document.querySelector('.title-bar h3');
          if (titleElement && titleElement.textContent !== data.title) {
            titleElement.textContent = data.title;
            console.log('Status poll: Title updated to "' + data.title + '"');
          }
        }
        
        // Update map location if changed
        if (data.location && data.location.latitude && data.location.longitude) {
          if (map && deviceMarker) {
            var newLatLng = [data.location.latitude, data.location.longitude];
            // Only update if location actually changed
            var currentLatLng = deviceMarker.getLatLng();
            if (currentLatLng.lat !== data.location.latitude || currentLatLng.lng !== data.location.longitude) {
              deviceMarker.setLatLng(newLatLng);
              // Don't auto-pan the map as it can be jarring during video playback
              // map.setView(newLatLng, 15);
              deviceMarker.setPopupContent('Device Location<br>Accuracy: ' + data.location.accuracy + 'm');
              console.log('Status poll: Location updated to', newLatLng);
            }
          }
        }
      });
      
      // Clear abort controller after successful request
      statusAbortController = null;
    })
    .catch(error => {
      if (error.name !== 'AbortError') {
        console.error('Status poll: Error fetching status:', error);
      }
      statusAbortController = null;
    });
}

// Optimized polling with requestIdleCallback
var statusPollInterval = null;

// Initialize Web Worker for background polling if supported
function initializeStatusWorker() {
  if (typeof Worker !== 'undefined') {
    try {
      statusWorker = new Worker('/js/status-worker.js');
      
      // Handle messages from worker
      statusWorker.addEventListener('message', function(e) {
        var message = e.data;
        
        if (message.type === 'status') {
          // Process status update in main thread with minimal impact
          requestAnimationFrame(function() {
            processStatusUpdate(message.data);
          });
        } else if (message.type === 'error') {
          console.error('Status worker error:', message.error);
        }
      });
      
      // Handle worker errors
      statusWorker.addEventListener('error', function(error) {
        console.error('Status worker error:', error);
        // Fallback to main thread polling
        statusWorker = null;
        startStatusPolling();
      });
      
      // Start worker polling
      statusWorker.postMessage({
        command: 'start',
        url: window.location.origin,
        interval: 10000
      });
      
      console.log('Status polling using Web Worker for better performance');
      return true;
    } catch (error) {
      console.error('Failed to create status worker:', error);
      statusWorker = null;
    }
  }
  return false;
}

// Process status update with minimal DOM manipulation
function processStatusUpdate(data) {
  // Update title if changed
  if (data.title) {
    var titleElement = document.querySelector('.title-bar h3');
    if (titleElement && titleElement.textContent !== data.title) {
      titleElement.textContent = data.title;
      console.log('Status poll: Title updated to "' + data.title + '"');
    }
  }
  
  // Update map location if changed
  if (data.location && data.location.latitude && data.location.longitude) {
    if (map && deviceMarker) {
      var newLatLng = [data.location.latitude, data.location.longitude];
      var currentLatLng = deviceMarker.getLatLng();
      if (currentLatLng.lat !== data.location.latitude || currentLatLng.lng !== data.location.longitude) {
        deviceMarker.setLatLng(newLatLng);
        deviceMarker.setPopupContent('Device Location<br>Accuracy: ' + data.location.accuracy + 'm');
        console.log('Status poll: Location updated to', newLatLng);
      }
    }
  }
}

function startStatusPolling() {
  // Try to use Web Worker first
  if (initializeStatusWorker()) {
    return;
  }
  
  // Fallback to optimized main thread polling
  console.log('Starting optimized status polling in main thread');
  
  // Clear any existing interval
  if (statusPollInterval) {
    clearInterval(statusPollInterval);
  }
  
  // Do immediate poll
  updateStatus();
  
  // Set up polling that respects browser idle time
  statusPollInterval = setInterval(function() {
    // Use requestIdleCallback if available to poll during idle time
    if ('requestIdleCallback' in window) {
      requestIdleCallback(updateStatus, { timeout: 2000 });
    } else {
      // Fallback to setTimeout to run in next tick
      setTimeout(updateStatus, 0);
    }
  }, 10000);
}

// Initialize on load
// Always initialize both video player and map
initializeMap();
initHLS();
startConnectionMonitor();
statsInterval = setInterval(updateStats, 200);

// Start optimized status polling
console.log('Starting optimized status polling - will poll every 10 seconds during idle time');
startStatusPolling();

// Cleanup on page unload
window.addEventListener('beforeunload', function() {
  if (hls) hls.destroy();
  if (reconnectTimer) clearTimeout(reconnectTimer);
  if (statsInterval) clearInterval(statsInterval);
  if (connectionCheckInterval) clearInterval(connectionCheckInterval);
  if (statusPollInterval) clearInterval(statusPollInterval);
  if (statusAbortController) statusAbortController.abort();
  if (statusWorker) {
    statusWorker.postMessage({ command: 'stop' });
    statusWorker.terminate();
  }
});