import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createApp, createStore } from '../src/app.js';

async function withServer(fn) {
  const app = createApp({ store: createStore() });
  const server = app.listen(0);
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn(base); } finally { server.close(); }
}

test('adds items and aggregates quantities', async () => {
  await withServer(async (base) => {
    const add = (body) => fetch(`${base}/api/cart/u1/items`, {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body),
    });
    assert.equal((await add({ productId: 'sku-1001', quantity: 2 })).status, 201);
    await add({ productId: 'sku-1001', quantity: 1 });
    const cart = await (await fetch(`${base}/api/cart/u1`)).json();
    assert.deepEqual(cart.items, [{ productId: 'sku-1001', quantity: 3 }]);
  });
});

test('rejects invalid quantity', async () => {
  await withServer(async (base) => {
    const res = await fetch(`${base}/api/cart/u1/items`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ productId: 'x', quantity: 0 }),
    });
    assert.equal(res.status, 422);
  });
});

test('exposes prometheus metrics', async () => {
  await withServer(async (base) => {
    const text = await (await fetch(`${base}/metrics`)).text();
    assert.match(text, /process_cpu_user_seconds_total/);
  });
});
