// Get elements
var video = document.getElementById('video');
var connectionStatus = document.getElementById('connectionStatus');

// Get configuration from injected values
var videoSrc = window.location.origin + window.APP_CONFIG.streamUrl;

// Browser detection - check in specific order
function detectBrowser() {
  var ua = navigator.userAgent;
  // Check Chrome first (includes "Safari" in UA)
  if (ua.indexOf('Chrome') > -1) {
    return 'Chrome';
  }
  // Check Firefox
  else if (ua.indexOf('Firefox') > -1) {
    return 'Firefox';
  }
  // Check Safari - must not contain Chrome or CriOS (Chrome on iOS)
  else if (ua.indexOf('Safari') > -1 && ua.indexOf('Chrome') === -1 && ua.indexOf('CriOS') === -1) {
    return 'Safari';
  }
  // Edge
  else if (ua.indexOf('Edg') > -1) {
    return 'Edge';
  }
  else {
    return 'Unknown';
  }
}

var browserName = detectBrowser();

// Debug browser detection
console.log('User Agent:', navigator.userAgent);
console.log('Detected Browser:', browserName);

// Logging via /forward-log endpoint (goes through centralized logging)
function udpLog(level, component, message) {
  var logMessage = 'JS|[' + browserName + '] [' + level + '] [' + component + '] ' + message;
  
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
udpLog('INFO', 'INIT', 'Browser detected: ' + browserName + ', UA: ' + navigator.userAgent);
udpLog('INFO', 'INIT', 'APP_CONFIG.streamUrl = ' + window.APP_CONFIG.streamUrl);
udpLog('INFO', 'INIT', 'Computed videoSrc = ' + videoSrc);

// State variables
var hls = null;
var reconnectTimer = null;
var statsInterval = null;
var lastSegmentTime = 0;
var connectionCheckInterval = null;
var hasConnectedOnce = false;

function setConnectionStatus(state) {
  connectionStatus.className = 'connection-indicator ' + state;
}

function initHLS() {
  if (hls) {
    hls.destroy();
  }
  
  // Use native HLS for Safari (even if MSE is available)
  if (!Hls.isSupported() || browserName === 'Safari') {
    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      udpLog('INFO', 'HLS', 'Using native HLS support for ' + browserName);
      // Use master playlist for Safari to ensure codec declaration
      var masterUrl = videoSrc.replace('/playlist.m3u8', '/master.m3u8');
      udpLog('INFO', 'HLS', 'Safari using master playlist: ' + masterUrl);
      video.src = masterUrl;
      setConnectionStatus('');
      
      // Set up comprehensive native video event handlers for Safari debugging
      video.addEventListener('loadstart', function() {
        udpLog('INFO', 'NATIVE', 'loadstart event fired');
      });
      
      video.addEventListener('loadedmetadata', function() {
        udpLog('INFO', 'NATIVE', 'Video metadata loaded - duration: ' + video.duration + ', videoWidth: ' + video.videoWidth + ', videoHeight: ' + video.videoHeight);
        // Check decode stats if available
        if (video.webkitDecodedFrameCount !== undefined) {
          udpLog('INFO', 'DECODE', 'Webkit decoded frames: ' + video.webkitDecodedFrameCount + ', dropped: ' + video.webkitDroppedFrameCount);
        }
      });
      
      video.addEventListener('loadeddata', function() {
        udpLog('INFO', 'NATIVE', 'loadeddata - readyState: ' + video.readyState + ', networkState: ' + video.networkState);
      });
      
      video.addEventListener('canplay', function() {
        udpLog('INFO', 'NATIVE', 'canplay event - buffered ranges: ' + video.buffered.length);
        for (var i = 0; i < video.buffered.length; i++) {
          udpLog('INFO', 'BUFFER', 'Range ' + i + ': ' + video.buffered.start(i) + ' - ' + video.buffered.end(i));
        }
      });
      
      video.addEventListener('canplaythrough', function() {
        udpLog('INFO', 'NATIVE', 'canplaythrough event fired');
      });
      
      video.addEventListener('playing', function() {
        udpLog('INFO', 'NATIVE', 'Video playing via native HLS');
        setConnectionStatus('');
      });
      
      video.addEventListener('waiting', function() {
        udpLog('WARN', 'NATIVE', 'waiting event - video is buffering');
      });
      
      video.addEventListener('stalled', function() {
        udpLog('WARN', 'NATIVE', 'stalled event - network stalled');
      });
      
      video.addEventListener('suspend', function() {
        udpLog('INFO', 'NATIVE', 'suspend event - browser stopped fetching');
      });
      
      video.addEventListener('progress', function() {
        udpLog('DEBUG', 'NATIVE', 'progress event - buffered: ' + (video.buffered.length > 0 ? video.buffered.end(0) : 0));
      });
      
      video.addEventListener('timeupdate', function() {
        // Only log occasionally to avoid spam
        if (Math.floor(video.currentTime) % 5 === 0 && video.currentTime % 1 < 0.1) {
          udpLog('INFO', 'PLAYBACK', 'currentTime: ' + video.currentTime + ', paused: ' + video.paused);
        }
      });
      
      video.addEventListener('error', function(e) {
        var errorDetails = {
          code: video.error ? video.error.code : 'N/A',
          message: video.error ? video.error.message : 'unknown',
          MEDIA_ERR_ABORTED: video.error && video.error.code === 1,
          MEDIA_ERR_NETWORK: video.error && video.error.code === 2,
          MEDIA_ERR_DECODE: video.error && video.error.code === 3,
          MEDIA_ERR_SRC_NOT_SUPPORTED: video.error && video.error.code === 4
        };
        udpLog('ERROR', 'NATIVE', 'Video error details: ' + JSON.stringify(errorDetails));
        
        // Check Safari-specific error info
        if (video.error && video.error.code === 3) {
          udpLog('ERROR', 'DECODE_ERROR', 'Media decode error - Safari cannot decode the video stream');
        }
      });
      
      // Check video playback quality if available
      if (video.getVideoPlaybackQuality) {
        setInterval(function() {
          var quality = video.getVideoPlaybackQuality();
          udpLog('INFO', 'QUALITY', 'Total frames: ' + quality.totalVideoFrames + 
                ', dropped: ' + quality.droppedVideoFrames + 
                ', corrupted: ' + quality.corruptedVideoFrames);
        }, 5000);
      }
      
      // Safari-specific: Check if we can get more info about the tracks
      video.addEventListener('loadedmetadata', function() {
        if (video.videoTracks && video.videoTracks.length > 0) {
          udpLog('INFO', 'TRACKS', 'Video tracks: ' + video.videoTracks.length);
          for (var i = 0; i < video.videoTracks.length; i++) {
            var track = video.videoTracks[i];
            udpLog('INFO', 'TRACK', 'Track ' + i + ': kind=' + track.kind + ', label=' + track.label + ', enabled=' + track.enabled);
          }
        }
        
        // Check text tracks (might have metadata)
        if (video.textTracks && video.textTracks.length > 0) {
          udpLog('INFO', 'TEXT_TRACKS', 'Text tracks: ' + video.textTracks.length);
        }
      });
      
      // Try to play with detailed error catching
      video.play().then(function() {
        udpLog('INFO', 'NATIVE', 'Play promise resolved successfully');
      }).catch(function(e) {
        udpLog('ERROR', 'PLAY_ERROR', 'Play failed: ' + e.name + ' - ' + e.message);
        if (e.name === 'NotAllowedError') {
          udpLog('INFO', 'AUTOPLAY', 'Autoplay blocked - waiting for user interaction');
          document.addEventListener('click', function() {
            video.muted = false;
            video.play().then(function() {
              udpLog('INFO', 'NATIVE', 'Play succeeded after user interaction');
            }).catch(function(e2) {
              udpLog('ERROR', 'PLAY_ERROR', 'Play still failed after interaction: ' + e2.message);
            });
          }, { once: true });
        }
      });
      
      // Safari-specific decode monitoring
      var decodeCheckCount = 0;
      var decodeCheckInterval = setInterval(function() {
        decodeCheckCount++;
        
        // Check various video states
        var stateInfo = {
          readyState: video.readyState,
          networkState: video.networkState,
          paused: video.paused,
          seeking: video.seeking,
          currentTime: video.currentTime,
          bufferedRanges: video.buffered.length,
          duration: video.duration,
          videoWidth: video.videoWidth,
          videoHeight: video.videoHeight
        };
        
        // Check webkit-specific properties
        if (video.webkitDecodedFrameCount !== undefined) {
          stateInfo.webkitDecodedFrames = video.webkitDecodedFrameCount;
          stateInfo.webkitDroppedFrames = video.webkitDroppedFrameCount;
        }
        
        // Check if we have presentation stats
        if (video.webkitVideoDecodedByteCount !== undefined) {
          stateInfo.decodedBytes = video.webkitVideoDecodedByteCount;
        }
        
        udpLog('DEBUG', 'DECODE_STATE', 'Check #' + decodeCheckCount + ': ' + JSON.stringify(stateInfo));
        
        // Stop after 20 checks (20 seconds)
        if (decodeCheckCount >= 20) {
          clearInterval(decodeCheckInterval);
          udpLog('INFO', 'DECODE_STATE', 'Stopped monitoring after 20 checks');
        }
      }, 1000);
    } else {
      udpLog('ERROR', 'HLS', 'HLS not supported in this browser');
      setConnectionStatus('error');
    }
    return;
  }
  
  hls = new Hls({
    debug: false, // Disable debug logging for production
    enableWorker: true,  // Use Web Worker for demuxing to prevent UI blocking
    lowLatencyMode: false, // Disable aggressive low latency for stability
    liveBackBufferLength: 24, // Keep 24 seconds of past video in buffer
    liveSyncDurationCount: 2, // Target playback position: 2 segments from live edge
    liveMaxLatencyDurationCount: 6, // Maximum allowed latency: 6 segments from live edge
    maxBufferLength: 32, // Forward buffer: 32 seconds of upcoming video
    maxMaxBufferLength: 80, // Maximum total buffer: 80 seconds
    maxBufferSize: 30 * 1024 * 1024, // 30 MB buffer size limit for memory management
    maxBufferHole: 0.5, // Skip gaps up to 0.5 seconds in buffer
    highBufferWatchdogPeriod: 3,  // Check every 3 seconds if buffer is too high
    nudgeOffset: 0.5, // Nudge playback by 0.5 seconds when catching up to live
    nudgeMaxRetry: 5,  // Try nudging up to 5 times before giving up
    maxFragLookUpTolerance: 0.5,  // Fragment lookup tolerance: 0.5 seconds
    liveDurationInfinity: true,  // Treat live streams as having infinite duration
    startLevel: -1,  // Auto-select quality level (-1 = automatic)
    fragLoadingTimeOut: 30000, // Fragment load timeout: 30 seconds
    fragLoadingMaxRetry: 10,  // Retry fragment loading up to 10 times
    fragLoadingRetryDelay: 2000, // Wait 2 seconds between fragment retries
    manifestLoadingTimeOut: 15000, // Playlist load timeout: 15 seconds
    manifestLoadingMaxRetry: 5,  // Retry playlist loading up to 5 times
    manifestLoadingRetryDelay: 1000,  // Wait 1 second between playlist retries
    // Additional settings to prevent stalling
    initialLiveManifestSize: 2, // Wait for 2 segments in playlist before starting
    stretchShortVideoTrack: true,  // Stretch video if duration mismatches audio
    forceKeyFrameOnDiscontinuity: true,  // Force keyframe at discontinuities
    // Stall detection settings
    stallDebounceMs: 1000,  // Wait 1 second before declaring a stall
    jumpThreshold: 0.5  // Jump forward if stalled for more than 0.5 seconds
  });
  
  setConnectionStatus('connecting');
  
  udpLog('INFO', 'HLS', 'Loading HLS source: ' + videoSrc);
  hls.loadSource(videoSrc);
  hls.attachMedia(video);
  
  hls.on(Hls.Events.MANIFEST_PARSED, function(event, data) {
    hasConnectedOnce = true;
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
      setConnectionStatus('error');
      // Reload the page after a short delay
      setTimeout(function() {
        window.location.reload();
      }, 1000);
      return;
    }
    
    if (data.fatal) {
      udpLog('ERROR', 'HLS', 'Fatal error - attempting reconnect');
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
  
  // Log stats every 5 seconds
  if (Date.now() - lastStatsLog > 5000) {
    lastStatsLog = Date.now();
    udpLog('INFO', 'STATS', 'Buffer: ' + bufferLen + 's, Bitrate: ' + bitrate + ', Time: ' + currentTime + 's, Latency: ' + estimatedLatency);
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
udpLog('INFO', 'PAGE', 'Page loaded');
udpLog('INFO', 'PAGE', 'User Agent: ' + navigator.userAgent);

// Always initialize HLS for all browsers (Safari blocking removed)
udpLog('INFO', 'PAGE', 'Initializing HLS player for ' + browserName);
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
  udpLog('INFO', 'PAGE', 'Page unloading - cleaned up resources');
});