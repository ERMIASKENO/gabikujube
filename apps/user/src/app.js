// user: registration, login and JWT issuing (RS256).
// The public key is published at /.well-known/jwks.json, which the Istio
// RequestAuthentication at the edge uses to validate tokens BEFORE requests
// reach any service (gateway-level auth). In production you would typically
// delegate identity to Entra External ID and keep this service for profiles.
import crypto from 'node:crypto';
import { promisify } from 'node:util';
import express from 'express';
import client from 'prom-client';
import { SignJWT, jwtVerify, exportJWK, importJWK, generateKeyPair } from 'jose';

const scrypt = promisify(crypto.scrypt);
export const ISSUER = process.env.JWT_ISSUER ?? 'https://shop.example.com';
export const AUDIENCE = 'shopsphere';

export async function loadKeys() {
  // Same key on every replica: injected from Key Vault by External Secrets.
  if (process.env.JWT_PRIVATE_JWK) {
    const jwk = JSON.parse(process.env.JWT_PRIVATE_JWK);
    const { d, p, q, dp, dq, qi, ...pub } = jwk; // eslint-disable-line no-unused-vars
    return { privateKey: await importJWK(jwk, 'RS256'), publicJwk: { ...pub, alg: 'RS256', use: 'sig' } };
  }
  const { privateKey, publicKey } = await generateKeyPair('RS256', { extractable: true });
  const publicJwk = { ...(await exportJWK(publicKey)), kid: 'dev', alg: 'RS256', use: 'sig' };
  return { privateKey, publicJwk, publicKey };
}

async function hashPassword(password, salt = crypto.randomBytes(16)) {
  const key = await scrypt(password, salt, 64);
  return `${salt.toString('hex')}:${key.toString('hex')}`;
}

async function verifyPassword(password, stored) {
  const [saltHex, keyHex] = stored.split(':');
  const key = await scrypt(password, Buffer.from(saltHex, 'hex'), 64);
  return crypto.timingSafeEqual(key, Buffer.from(keyHex, 'hex'));
}

export function createApp({ keys, state = { ready: true } }) {
  const users = new Map(); // demo store; production => PostgreSQL
  const app = express();
  app.disable('x-powered-by');
  app.use(express.json({ limit: '16kb' }));

  const registry = new client.Registry();
  client.collectDefaultMetrics({ register: registry });
  const logins = new client.Counter({ name: 'user_logins_total', help: 'Logins', labelNames: ['result'], registers: [registry] });

  app.get('/healthz', (_q, r) => r.json({ status: 'ok' }));
  app.get('/readyz', (_q, r) => r.status(state.ready ? 200 : 503).json({ ready: state.ready }));
  app.get('/metrics', async (_q, r) => { r.set('Content-Type', registry.contentType); r.end(await registry.metrics()); });
  app.get('/.well-known/jwks.json', (_q, r) => r.set('Cache-Control', 'public, max-age=300').json({ keys: [keys.publicJwk] }));

  app.post('/api/users/register', async (req, res) => {
    const { email, password, name } = req.body ?? {};
    if (!/^[^@\s]+@[^@\s]+$/.test(email ?? '') || (password ?? '').length < 10) {
      return res.status(422).json({ error: 'valid email and password (min 10 chars) required' });
    }
    if (users.has(email)) return res.status(409).json({ error: 'already registered' });
    const id = crypto.randomUUID();
    users.set(email, { id, email, name, hash: await hashPassword(password) });
    res.status(201).json({ id, email, name });
  });

  app.post('/api/users/login', async (req, res) => {
    const { email, password } = req.body ?? {};
    const u = users.get(email);
    if (!u || !(await verifyPassword(password ?? '', u.hash))) {
      logins.inc({ result: 'failure' });
      return res.status(401).json({ error: 'invalid credentials' });
    }
    logins.inc({ result: 'success' });
    const accessToken = await new SignJWT({ email: u.email, name: u.name })
      .setProtectedHeader({ alg: 'RS256', kid: keys.publicJwk.kid })
      .setSubject(u.id).setIssuer(ISSUER).setAudience(AUDIENCE)
      .setIssuedAt().setExpirationTime('15m')
      .sign(keys.privateKey);
    res.json({ accessToken, tokenType: 'Bearer', expiresIn: 900 });
  });

  app.get('/api/users/me', async (req, res) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer /, '');
    try {
      const key = keys.publicKey ?? (await importJWK(keys.publicJwk, 'RS256'));
      const { payload } = await jwtVerify(token, key, { issuer: ISSUER, audience: AUDIENCE });
      res.json({ id: payload.sub, email: payload.email, name: payload.name });
    } catch {
      res.status(401).json({ error: 'unauthorized' });
    }
  });
  return app;
}
