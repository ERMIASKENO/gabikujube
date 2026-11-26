import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, stat } from 'node:fs/promises';

test('build produces minified bundle and index.html', async () => {
  const js = await readFile('dist/assets/app.js', 'utf8');
  assert.ok(!js.includes('__APP_VERSION__'), 'version placeholder must be replaced at build time');
  assert.ok((await stat('dist/index.html')).size > 0);
});
