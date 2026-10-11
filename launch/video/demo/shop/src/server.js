import http from 'node:http';
import { handleCallback } from './auth/callback.js';
import { renderDashboard } from './dashboard.js';

const port = process.env.PORT || 3000;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  if (url.pathname === '/auth/google/callback') return handleCallback(url, res);
  if (url.pathname === '/dashboard') return renderDashboard(req, res);
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end('<h1>shop</h1><a href="/auth/google">Sign in with Google</a>');
});

server.listen(port, () => console.log(`shop on http://localhost:${port}`));
