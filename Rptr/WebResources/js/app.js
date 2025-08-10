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

// Logging via /forward-log endpoint (goes through centralized logging)
function udpLog(level, component, message) {
  var logMessage = 'JS|[' + level + '] [' + component + '] ' + message;
  
  // Send to iOS app's /forward-log endpoint which forwards through RptrLogger
  fetch(window.location.origin + '/forward-log', {
    method: 'POST',
    headers: { 'Content-Type': 'text/plain' },
    body: logMessage,
    keepalive: true
  }).catch(function(err) {
    console.error('Failed to send log:', err);
  });
  
  // Also log to console for debugging
  console.log(logMessage);
}

// Debug logging to track URL usage
udpLog('INFO', 'INIT', 'APP_CONFIG.streamUrl = ' + window.APP_CONFIG.streamUrl);
udpLog('INFO', 'INIT', 'Computed videoSrc = ' + videoSrc);

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
    liveBackBufferLength: 24, // Keep 24 seconds of back buffer (6 segments)
    liveSyncDurationCount: 2, // Stay 2 segments (8 seconds) from edge
    liveMaxLatencyDurationCount: 6, // Allow up to 6 segments latency (24 seconds)
    maxBufferLength: 32, // Buffer up to 32 seconds (8 segments)
    maxMaxBufferLength: 80, // Allow up to 80 seconds (20 segments)
    maxBufferSize: 30 * 1024 * 1024, // 30 MB buffer size (reduced for mobile)
    maxBufferHole: 0.5, // More tolerant of gaps
    highBufferWatchdogPeriod: 3,
    nudgeOffset: 0.5, // Less aggressive nudging
    nudgeMaxRetry: 5,
    maxFragLookUpTolerance: 0.5,
    liveDurationInfinity: true,
    startLevel: -1,
    fragLoadingTimeOut: 30000, // 30 second timeout for 6-second segments
    fragLoadingMaxRetry: 10,
    fragLoadingRetryDelay: 2000, // 2 second retry delay
    manifestLoadingTimeOut: 15000, // 15 second manifest timeout
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
  
  udpLog('INFO', 'HLS', 'Loading HLS source: ' + videoSrc);
  hls.loadSource(videoSrc);
  hls.attachMedia(video);
  
  hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
    hasConnectedOnce = true;
    status.innerHTML = 'Stream connected - Starting playback';
    setConnectionStatus('');
    udpLog('INFO', 'HLS', 'Manifest parsed - levels: ' + (data ? data.levels.length : 0));
    
    // Check if this is a live stream
    if (hls.levels && hls.levels.length > 0) {
      var level = hls.levels[0];
      udpLog('INFO', 'CODEC', 'Video: ' + (level.videoCodec || 'unknown') + ', Audio: ' + (level.audioCodec || 'none'));
      if (level.details && level.details.live) {
        udpLog('INFO', 'HLS', 'Live stream detected');
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
    udpLog('INFO', 'VIDEO', 'Video playing - duration: ' + video.duration);
    
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
  
  // Track init segment parsing
  hls.on(Hls.Events.FRAG_PARSING_INIT_SEGMENT, function(event, data) {
    udpLog('INFO', 'INIT_PARSE', 'Parsing init segment');
    if (data.tracks) {
      if (data.tracks.video) {
        var v = data.tracks.video;
        udpLog('INFO', 'VIDEO_TRACK', 'codec=' + v.codec + ', size=' + v.width + 'x' + v.height + ', timescale=' + v.timescale);
        if (v.timescale) {
          udpLog('INFO', 'VIDEO_TIMESCALE', 'Video track timescale: ' + v.timescale);
        }
      }
    }
  });
  
  // Track fragment parsing
  hls.on(Hls.Events.FRAG_PARSING_DATA, function(event, data) {
    udpLog('DEBUG', 'PARSE_DATA', 'Type=' + data.type + ', samples=' + data.nb + ', pts=' + data.startPTS + '-' + data.endPTS);
  });
  
  // Track buffer operations with more detail
  hls.on(Hls.Events.BUFFER_APPENDING, function(event, data) {
    udpLog('DEBUG', 'BUFFER_APPEND', 'Type=' + data.type + ', size=' + data.data.byteLength);
    
    // Check what type of data we have
    var dataType = Object.prototype.toString.call(data.data);
    udpLog('DEBUG', 'BUFFER_TYPE', 'Data type: ' + dataType);
    
    // Get the actual ArrayBuffer
    var buffer = null;
    if (data.data instanceof ArrayBuffer) {
      buffer = data.data;
    } else if (data.data.buffer instanceof ArrayBuffer) {
      // It might be a TypedArray view
      buffer = data.data.buffer;
    }
    
    // Check first bytes to detect format
    if (buffer && buffer.byteLength > 8) {
      var showBytes = Math.min(buffer.byteLength, 200);
      var arr = new Uint8Array(buffer, 0, showBytes);
      var hex = Array.from(arr, function(b) { return ('0' + b.toString(16)).slice(-2); }).join(' ');
      udpLog('DEBUG', 'BUFFER_HEX', 'First ' + showBytes + ' bytes: ' + hex);
      
      // Check for box types
      try {
        var view = new DataView(buffer);
        var pos = 0;
        var boxes = [];
        var boxDetails = [];
        
        while (pos < Math.min(buffer.byteLength, 1000)) {
          if (pos + 8 > buffer.byteLength) break;
          var size = view.getUint32(pos);
          var type = String.fromCharCode(
            view.getUint8(pos + 4),
            view.getUint8(pos + 5),
            view.getUint8(pos + 6),
            view.getUint8(pos + 7)
          );
          boxes.push(type + '(' + size + ')');
          
          // Log details for specific boxes
          if (type === 'tfdt') {
            if (pos + 16 <= buffer.byteLength) {
              var version = view.getUint8(pos + 8);
              var decodeTime = 0;
              if (version === 0) {
                decodeTime = view.getUint32(pos + 12);
              } else {
                // 64-bit decode time - read high and low parts
                var high = view.getUint32(pos + 12);
                var low = view.getUint32(pos + 16);
                decodeTime = high * 0x100000000 + low;
              }
              boxDetails.push('tfdt decode_time=' + decodeTime);
            }
          } else if (type === 'trun') {
            if (pos + 16 <= buffer.byteLength) {
              var trunFlags = view.getUint32(pos + 8);
              var sampleCount = view.getUint32(pos + 12);
              boxDetails.push('trun samples=' + sampleCount + ' flags=0x' + trunFlags.toString(16));
            }
          } else if (type === 'mvhd') {
            if (pos + 20 <= buffer.byteLength) {
              var mvhdVersion = view.getUint8(pos + 8);
              var timescale = view.getUint32(pos + (mvhdVersion === 0 ? 20 : 28));
              boxDetails.push('mvhd timescale=' + timescale);
            }
          }
          
          pos += size;
          if (size === 0 || size === 1) break;
        }
        
        if (boxes.length > 0) {
          udpLog('DEBUG', 'BOXES', 'Found boxes: ' + boxes.join(', '));
          if (boxDetails.length > 0) {
            udpLog('DEBUG', 'BOX_DETAILS', boxDetails.join(', '));
          }
        }
      } catch (e) {
        udpLog('DEBUG', 'BOXES', 'Error parsing boxes: ' + e.message + ' Stack: ' + e.stack);
      }
    } else {
      udpLog('WARN', 'BUFFER_APPEND', 'Could not extract ArrayBuffer from data');
    }
  });
  
  hls.on(Hls.Events.FRAG_LOADED, function(event, data) {
    lastSegmentTime = Date.now();
    udpLog('DEBUG', 'FRAG', 'Fragment loaded: ' + data.frag.sn + ', duration: ' + data.frag.duration + 's');
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
    udpLog('ERROR', 'HLS', 'Error: ' + data.type + ' - ' + data.details + ' (Fatal: ' + data.fatal + ')');
    
    // Check for 410 Gone error which indicates URL was regenerated
    if (data.type === Hls.ErrorTypes.NETWORK_ERROR && data.response && data.response.code === 410) {
      udpLog('WARN', 'HLS', 'URL regenerated (410 Gone) - reloading page');
      status.innerHTML = 'Stream URL changed - Reloading...';
      setConnectionStatus('error');
      // Reload the page after a short delay
      setTimeout(function() {
        window.location.reload();
      }, 1000);
      return;
    }
    
    if (data.fatal) {
      udpLog('ERROR', 'HLS', 'Fatal error - attempting reconnect');
      status.innerHTML = 'Connection lost - Reconnecting...';
      setConnectionStatus('error');
      scheduleReconnect();
    } else {
      // Non-fatal errors, try to recover
      if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
        udpLog('WARN', 'HLS', 'Network error - restarting load');
        hls.startLoad();
      } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
        udpLog('WARN', 'HLS', 'Media error - attempting recovery');
        // Log more details about the media error
        if (data.details === Hls.ErrorDetails.BUFFER_APPENDING_ERROR) {
          udpLog('ERROR', 'MSE', 'Buffer append failed - checking source buffer state');
          udpLog('ERROR', 'MSE_DETAILS', 'Error details: ' + JSON.stringify({
            type: data.type,
            details: data.details,
            fatal: data.fatal,
            reason: data.reason,
            frag: data.frag ? data.frag.sn : 'N/A'
          }));
          if (video.error) {
            udpLog('ERROR', 'MSE', 'Video error: ' + video.error.code + ' - ' + video.error.message);
          }
          // Try to get more info from the error event
          if (data.err) {
            udpLog('ERROR', 'MSE', 'Original error: ' + data.err.toString());
            if (data.err.stack) {
              udpLog('ERROR', 'MSE_STACK', 'Stack: ' + data.err.stack.substring(0, 500));
            }
          }
        } else if (data.details === Hls.ErrorDetails.FRAG_PARSING_ERROR) {
          udpLog('ERROR', 'PARSE', 'Fragment parsing error');
          if (data.reason) {
            udpLog('ERROR', 'PARSE_REASON', 'Reason: ' + data.reason);
          }
        }
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

var lastStatsLog = 0;
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
  
  // Log stats every 5 seconds
  if (Date.now() - lastStatsLog > 5000) {
    lastStatsLog = Date.now();
    udpLog('INFO', 'STATS', 'Buffer: ' + bufferLen + 's, Bitrate: ' + bitrate + ', Time: ' + currentTime + 's, Latency: ' + estimatedLatency);
  }
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

// Initialize on load
udpLog('INFO', 'PAGE', 'Page loaded, initializing HLS player');
udpLog('INFO', 'PAGE', 'User Agent: ' + navigator.userAgent);
initHLS();
startConnectionMonitor();
statsInterval = setInterval(updateStats, 200);
udpLog('INFO', 'PAGE', 'Initialization complete');

// Cleanup on page unload
window.addEventListener('beforeunload', function() {
  if (hls) hls.destroy();
  if (reconnectTimer) clearTimeout(reconnectTimer);
  if (statsInterval) clearInterval(statsInterval);
  if (connectionCheckInterval) clearInterval(connectionCheckInterval);
});