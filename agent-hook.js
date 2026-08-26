#!/usr/bin/env node
// PreToolUse hook forwarder for the samurai-patrick-command-center dashboard.
// Claude Code invokes this as a command hook before every tool call. It reads
// the hook payload from stdin and POSTs it to the dashboard's fixed local
// sidecar (agent-events-server.js, port 3005) so the Agents panel can show
// live activity instead of polling. Unlike agent-flow's version of this
// script, there's exactly one dashboard instance at a fixed port, so no
// discovery-file lookup is needed.
'use strict';
const http = require('http');

// Hard safety deadline — guarantees this process exits quickly no matter what
// happens (stdin stall, dashboard not running, HTTP hang). A hook that never
// exits would block the agent's turn, so this is not optional.
setTimeout(() => process.exit(0), 2000);

let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => {
  input += c;
});
process.stdin.on('end', () => {
  if (!input) process.exit(0);

  const req = http.request(
    {
      hostname: '127.0.0.1',
      port: 3005,
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      timeout: 1000,
    },
    (res) => {
      res.resume();
      res.on('end', () => process.exit(0));
    }
  );
  req.on('error', () => process.exit(0));
  req.on('timeout', () => req.destroy());
  req.write(input);
  req.end();
});
