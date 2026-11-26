import { createClient } from 'redis';
import { createApp, createStore } from './app.js';

const port = Number(process.env.PORT ?? 8080);
const state = { ready: true };

let redis;
if (process.env.REDIS_URL) {
  // Azure Managed Redis: TLS on 10000, clustered by default. With workload
  // identity you would use an Entra token as the password (see docs/ARCHITECTURE.md).
  redis = createClient({
    url: process.env.REDIS_URL,
    password: process.env.REDIS_PASSWORD,
    socket: { reconnectStrategy: (retries) => Math.min(retries * 100, 3000) },
  });
  redis.on('error', (err) => console.error(JSON.stringify({ level: 'error', msg: 'redis', err: err.message })));
  await redis.connect();
}

const app = createApp({ store: createStore({ redis }), state });
const server = app.listen(port, () =>
  console.log(JSON.stringify({ level: 'info', msg: 'starting', service: 'cart', port })));

// Graceful shutdown: fail readiness, wait for endpoint removal, drain, exit.
process.on('SIGTERM', () => {
  state.ready = false;
  setTimeout(() => {
    server.close(async () => {
      await redis?.quit().catch(() => {});
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 20_000).unref();
  }, 5_000);
});
