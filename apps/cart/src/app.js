// cart: per-user shopping cart backed by Azure Managed Redis (in-memory fallback
// for local dev/tests). Stateless pods => horizontally scalable via HPA.
import express from 'express';
import client from 'prom-client';

export function createStore({ redis } = {}) {
  if (redis) {
    const key = (u) => `cart:${u}`;
    return {
      async get(userId) {
        const raw = await redis.hGetAll(key(userId));
        return Object.entries(raw).map(([productId, qty]) => ({ productId, quantity: Number(qty) }));
      },
      async add(userId, productId, quantity) {
        await redis.hIncrBy(key(userId), productId, quantity);
        await redis.expire(key(userId), 60 * 60 * 24 * 7); // abandoned carts expire after 7 days
      },
      async clear(userId) { await redis.del(key(userId)); },
      async ping() { return (await redis.ping()) === 'PONG'; },
    };
  }
  const carts = new Map();
  return {
    async get(userId) {
      return [...(carts.get(userId) ?? new Map())].map(([productId, quantity]) => ({ productId, quantity }));
    },
    async add(userId, productId, quantity) {
      const c = carts.get(userId) ?? new Map();
      c.set(productId, (c.get(productId) ?? 0) + quantity);
      carts.set(userId, c);
    },
    async clear(userId) { carts.delete(userId); },
    async ping() { return true; },
  };
}

export function createApp({ store, state = { ready: true } }) {
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '32kb' }));

  const registry = new client.Registry();
  client.collectDefaultMetrics({ register: registry });
  const httpRequests = new client.Counter({
    name: 'http_requests_total', help: 'HTTP requests', labelNames: ['route', 'method', 'code'], registers: [registry],
  });
  const httpDuration = new client.Histogram({
    name: 'http_request_duration_seconds', help: 'HTTP latency', labelNames: ['route', 'method'],
    buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5], registers: [registry],
  });

  app.use((req, res, next) => {
    const end = httpDuration.startTimer();
    res.on('finish', () => {
      const route = req.route?.path ?? 'unmatched';
      httpRequests.inc({ route, method: req.method, code: res.statusCode });
      end({ route, method: req.method });
    });
    next();
  });

  app.get('/healthz', (_req, res) => res.json({ status: 'ok', version: process.env.APP_VERSION ?? 'dev' }));
  app.get('/readyz', async (_req, res) => {
    // Readiness checks a hard dependency (Redis); liveness never does, otherwise
    // a Redis blip would restart every pod (cascading failure).
    const ok = state.ready && (await store.ping().catch(() => false));
    res.status(ok ? 200 : 503).json({ status: ok ? 'ready' : 'not-ready' });
  });
  app.get('/metrics', async (_req, res) => {
    res.set('Content-Type', registry.contentType);
    res.end(await registry.metrics());
  });

  app.get('/api/cart/:userId', async (req, res, next) => {
    try { res.json({ userId: req.params.userId, items: await store.get(req.params.userId) }); } catch (e) { next(e); }
  });

  app.post('/api/cart/:userId/items', async (req, res, next) => {
    const { productId, quantity = 1 } = req.body ?? {};
    if (typeof productId !== 'string' || !Number.isInteger(quantity) || quantity < 1 || quantity > 99) {
      return res.status(422).json({ error: 'productId (string) and quantity (1-99) are required' });
    }
    try {
      await store.add(req.params.userId, productId, quantity);
      res.status(201).json({ userId: req.params.userId, items: await store.get(req.params.userId) });
    } catch (e) { next(e); }
  });

  app.delete('/api/cart/:userId', async (req, res, next) => {
    try { await store.clear(req.params.userId); res.status(204).end(); } catch (e) { next(e); }
  });

  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    console.error(JSON.stringify({ level: 'error', msg: err.message }));
    res.status(500).json({ error: 'internal error' });
  });
  return app;
}
