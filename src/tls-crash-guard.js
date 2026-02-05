// Guard against a known Node.js TLS bug where TLSSocket._handle is null
// when undici passes a cached session to tls.connect().
//
// Stack trace:
//   TypeError: Cannot read properties of null (reading 'setSession')
//       at TLSSocket.setSession (node:_tls_wrap)
//       at Object.connect (node:_tls_wrap)
//       at Client.connect (undici/lib/core/connect.js)
//
// The error is safe to swallow — the connection was never established,
// and undici will retry it. However, if the error fires repeatedly in a
// tight loop (undici retries immediately), we exit after a threshold to
// avoid burning CPU. The wrapper will restart the gateway.
//
// Load via: NODE_OPTIONS='--require /app/src/tls-crash-guard.js'

const TLS_BUG_MSG = "Cannot read properties of null (reading 'setSession')";
const MAX_HITS = 5;
const WINDOW_MS = 10_000;

let hits = 0;
let windowStart = Date.now();

process.on('uncaughtException', (err, origin) => {
  if (err?.message === TLS_BUG_MSG) {
    const now = Date.now();
    if (now - windowStart > WINDOW_MS) {
      hits = 0;
      windowStart = now;
    }
    hits++;
    if (hits <= MAX_HITS) {
      console.error(`[tls-guard] Caught known Node.js TLS session bug (${hits}/${MAX_HITS} in window)`);
      return;
    }
    console.error(`[tls-guard] TLS bug hit ${hits} times in ${WINDOW_MS / 1000}s — exiting to avoid spin loop`);
    process.exit(1);
  }
  console.error('[fatal] Uncaught exception:', err);
  process.exit(1);
});
