import { createApp, loadKeys } from './app.js';

const state = { ready: true };
const app = createApp({ keys: await loadKeys(), state });
const server = app.listen(Number(process.env.PORT ?? 8080), () =>
  console.log(JSON.stringify({ level: 'info', msg: 'starting', service: 'user' })));

process.on('SIGTERM', () => {
  state.ready = false;
  setTimeout(() => server.close(() => process.exit(0)), 5_000);
  setTimeout(() => process.exit(1), 25_000).unref();
});
