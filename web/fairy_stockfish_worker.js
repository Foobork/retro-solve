// Web Worker bridge for Fairy-Stockfish WebAssembly
self.onerror = function (message, source, lineno, colno, error) {
  var errText = 'WORKER_ONERROR: ' + message + ' (' + source + ':' + lineno + ':' + colno + ') ' + (error ? (error.stack || error) : '');
  console.error(errText);
  self.postMessage(errText);
};

let engine = null;
const messageQueue = [];

function send(cmd) {
  if (cmd === 'quit') {
    try {
      if (engine && typeof engine.terminate === 'function') {
        engine.terminate();
      }
    } catch (_) {}
    self.close();
    return;
  }
  if (engine) {
    engine.postMessage(cmd);
  } else {
    messageQueue.push(cmd);
  }
}

self.onmessage = function (e) {
  if (typeof e.data === 'string') {
    send(e.data);
  }
};

try {
  importScripts('stockfish.js');

  const sfUrl = new URL('stockfish.js', self.location.href).href;

  Stockfish({
    mainScriptUrlOrBlob: sfUrl,
    locateFile: function (path) {
      return new URL(path, self.location.href).href;
    }
  })
    .then(function (sf) {
      engine = sf;
      sf.addMessageListener(function (line) {
        self.postMessage(line);
      });
      while (messageQueue.length > 0) {
        engine.postMessage(messageQueue.shift());
      }
    })
    .catch(function (err) {
      var errStr = '[fairy_stockfish_worker] Stockfish promise rejection: ' + err + '\n' + (err ? err.stack : '');
      console.error(errStr);
      self.postMessage('WORKER_ERROR: ' + errStr);
    });
} catch (err) {
  var errStr = '[fairy_stockfish_worker] Fatal top-level error: ' + err + '\n' + (err ? err.stack : '');
  console.error(errStr);
  self.postMessage('WORKER_ERROR: ' + errStr);
}
