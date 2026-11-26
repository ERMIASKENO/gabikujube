import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp, loadKeys } from '../src/app.js';

test('register -> login -> me round trip with RS256 JWT', async () => {
  const app = createApp({ keys: await loadKeys() });
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  const json = (path, body, headers = {}) => fetch(base + path, {
    method: body ? 'POST' : 'GET',
    headers: { 'content-type': 'application/json', ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  try {
    assert.equal((await json('/api/users/register', { email: 'a@b.io', password: 'correct-horse', name: 'Ada' })).status, 201);
    assert.equal((await json('/api/users/login', { email: 'a@b.io', password: 'wrong-password' })).status, 401);
    const { accessToken } = await (await json('/api/users/login', { email: 'a@b.io', password: 'correct-horse' })).json();
    const me = await (await json('/api/users/me', undefined, { authorization: `Bearer ${accessToken}` })).json();
    assert.equal(me.email, 'a@b.io');
    const jwks = await (await json('/.well-known/jwks.json')).json();
    assert.equal(jwks.keys[0].kty, 'RSA');
    assert.equal(jwks.keys[0].d, undefined, 'private part must never be published');
  } finally {
    server.close();
  }
});
