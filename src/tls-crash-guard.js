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
// and undici will retry it.
//
// Load via: NODE_OPTIONS='--require /app/src/tls-crash-guard.js'

process.on('uncaughtException', (err, origin) => {
  if (err?.message === "Cannot read properties of null (reading 'setSession')") {
    console.error('[tls-guard] Caught known Node.js TLS session bug — connection will retry');
    return;
  }
  console.error('[fatal] Uncaught exception:', err);
  process.exit(1);
});
