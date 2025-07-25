// Web Worker for background status polling
// This runs in a separate thread to avoid interfering with video playback

var pollInterval = null;
var currentRequest = null;

// Handle messages from main thread
self.addEventListener('message', function(e) {
  var data = e.data;
  
  switch(data.command) {
    case 'start':
      startPolling(data.url, data.interval || 10000);
      break;
    case 'stop':
      stopPolling();
      break;
    case 'poll':
      pollStatus(data.url);
      break;
  }
});

function startPolling(baseUrl, interval) {
  // Clear any existing interval
  stopPolling();
  
  // Do immediate poll
  pollStatus(baseUrl);
  
  // Set up interval
  pollInterval = setInterval(function() {
    pollStatus(baseUrl);
  }, interval);
}

function stopPolling() {
  if (pollInterval) {
    clearInterval(pollInterval);
    pollInterval = null;
  }
  if (currentRequest) {
    // Note: Can't abort fetch in workers in older browsers
    currentRequest = null;
  }
}

function pollStatus(baseUrl) {
  var requestUrl = baseUrl + '/status';
  
  // Perform fetch in worker thread
  currentRequest = fetch(requestUrl, {
    method: 'GET',
    cache: 'no-store'
  })
    .then(function(response) {
      if (!response.ok) {
        throw new Error('Response not ok: ' + response.status);
      }
      return response.json();
    })
    .then(function(data) {
      // Send data back to main thread
      self.postMessage({
        type: 'status',
        data: data,
        timestamp: Date.now()
      });
      currentRequest = null;
    })
    .catch(function(error) {
      // Send error back to main thread
      self.postMessage({
        type: 'error',
        error: error.message,
        timestamp: Date.now()
      });
      currentRequest = null;
    });
}