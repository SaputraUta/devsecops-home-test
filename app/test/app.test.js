const { test, before, after } = require('node:test');
const assert = require('node:assert');
const app = require('../src/app');

let server;
let base;

before(() => {
  server = app.listen(0);
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test('health returns ok', async () => {
  const res = await fetch(`${base}/health`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual(await res.json(), { status: 'ok' });
});

test('rejects a non-numeric order id', async () => {
  const res = await fetch(`${base}/api/orders/abc`);
  assert.strictEqual(res.status, 400);
});

test('does not advertise the framework', async () => {
  const res = await fetch(`${base}/health`);
  assert.strictEqual(res.headers.get('x-powered-by'), null);
});
