// Web Worker bridge for Fairy-Stockfish WebAssembly
importScripts('stockfish.js');

let engine = null;
const messageQueue = [];

function send(cmd) {
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

Stockfish()
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
    console.error('[fairy_stockfish_worker] Error initializing Stockfish:', err);
  });
