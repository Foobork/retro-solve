// Web Worker bridge for Fairy-Stockfish WebAssembly with NNUE support
self.onerror = function (message, source, lineno, colno, error) {
  var errText = 'WORKER_ONERROR: ' + message + ' (' + source + ':' + lineno + ':' + colno + ') ' + (error ? (error.stack || error) : '');
  console.error(errText);
  self.postMessage(errText);
};

let engine = null;
const messageQueue = [];

async function handleLoadNnue(filename) {
  try {
    if (!filename || filename === 'none' || filename === 'chess.nnue') {
      if (engine) {
        engine.postMessage('setoption name Use NNUE value false');
      }
      self.postMessage('WORKER_NNUE_STATUS: classical');
      return;
    }
    self.postMessage('WORKER_LOG: Fetching NNUE file ' + filename + ' ...');
    const nnueUrl = new URL(filename, self.location.href).href;
    const res = await fetch(nnueUrl);
    if (!res.ok) {
      self.postMessage('WORKER_LOG: NNUE file ' + filename + ' not found (' + res.status + '), fallback to classical');
      if (engine) {
        engine.postMessage('setoption name Use NNUE value false');
      }
      self.postMessage('WORKER_NNUE_STATUS: classical');
      return;
    }
    const buf = await res.arrayBuffer();
    if (engine && engine.FS) {
      engine.FS.writeFile(filename, new Uint8Array(buf));
      engine.postMessage('setoption name EvalFile value ' + filename);
      engine.postMessage('setoption name Use NNUE value true');
      self.postMessage('WORKER_LOG: NNUE ' + filename + ' (' + buf.byteLength + ' bytes) mounted successfully');
      self.postMessage('WORKER_NNUE_STATUS: enabled');
    }
  } catch (e) {
    self.postMessage('WORKER_ERROR: Failed to load NNUE file ' + filename + ': ' + e);
    if (engine) {
      engine.postMessage('setoption name Use NNUE value false');
    }
    self.postMessage('WORKER_NNUE_STATUS: classical');
  } finally {
    self.postMessage('WORKER_NNUE_DONE');
  }
}

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
  if (cmd.startsWith('LOAD_NNUE ')) {
    const filename = cmd.substring('LOAD_NNUE '.length).trim();
    if (engine) {
      handleLoadNnue(filename);
    } else {
      messageQueue.push(cmd);
    }
    return;
  }
  if (engine) {
    engine.postMessage(cmd);
  } else {
    messageQueue.push(cmd);
  }
}

self.onmessage = function (e) {
  var data = e.data;
  if (typeof data === 'string') {
    send(data);
  } else if (data != null) {
    send(String(data));
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
      self.postMessage('WORKER_LOG: Stockfish engine instance created');
      sf.addMessageListener(function (line) {
        self.postMessage(line);
      });
      while (messageQueue.length > 0) {
        const nextCmd = messageQueue.shift();
        if (nextCmd.startsWith('LOAD_NNUE ')) {
          handleLoadNnue(nextCmd.substring('LOAD_NNUE '.length).trim());
        } else {
          engine.postMessage(nextCmd);
        }
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
