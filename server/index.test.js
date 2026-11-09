import test, { before, after } from 'node:test';
import assert from 'node:assert/strict';
import { app } from './index.js';

let server;
let apiOrigin;

before(async () => {
  server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  apiOrigin = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server) await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
});

test('health endpoint responds with security headers and no secret values', async () => {
  const response = await fetch(`${apiOrigin}/api/health`, { headers: { Origin: 'http://localhost:5173' } });
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.ok, true);
  assert.equal(response.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(response.headers.get('x-frame-options'), 'DENY');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.equal(response.headers.get('access-control-allow-origin'), 'http://localhost:5173');
  assert.equal(JSON.stringify(body).includes('service_role'), false);
});

test('API rejects unapproved browser origins', async () => {
  const response = await fetch(`${apiOrigin}/api/health`, { headers: { Origin: 'https://attacker.example' } });
  assert.equal(response.status, 403);
  assert.match((await response.json()).error, /origin is not allowed/i);
});

test('API rejects oversized JSON payloads', async () => {
  const response = await fetch(`${apiOrigin}/api/assistant`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: 'x'.repeat(20_000) }),
  });
  assert.equal(response.status, 413);
  assert.match((await response.json()).error, /too large/i);
});
