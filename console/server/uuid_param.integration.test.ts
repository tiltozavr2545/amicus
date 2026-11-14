import assert from 'node:assert/strict';
import type { AddressInfo } from 'node:net';
import { after, before, describe, it } from 'node:test';
import express, { Router } from 'express';
import { uuidParam } from './uuid.ts';

// `uuid.test.ts` checks the shape, this one checks that `router.param` is
// actually on the request path: a garbage `:id` is rejected with 400 and never
// reaches the handler, for any router route with `:id`, not only the listed
// ones. The router is assembled the same way as in `routes/*.ts`, on an
// ephemeral port.
describe('uuidParam in express', () => {
  let base: string;
  let server: ReturnType<express.Express['listen']>;
  let reached = 0;

  before(async () => {
    const router = Router();
    router.param('id', uuidParam);
    router.get('/items/:id', (req, res) => {
      reached += 1;
      res.json({ id: req.params.id });
    });
    router.post('/items/:id/act', (_req, res) => {
      reached += 1;
      res.json({ ok: true });
    });
    router.get('/media/:name', (req, res) => {
      reached += 1;
      res.json({ name: req.params.name });
    });

    const app = express();
    app.use('/api', router);
    await new Promise<void>((resolve) => {
      server = app.listen(0, '127.0.0.1', () => resolve());
    });
    const { port } = server.address() as AddressInfo;
    base = `http://127.0.0.1:${port}/api`;
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  });

  it('lets a uuid through to the handler', async () => {
    reached = 0;
    const id = 'e5110c16-91e7-44ca-8075-348bca3efedd';
    const response = await fetch(`${base}/items/${id}`);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { id });
    assert.equal(reached, 1);
  });

  it('rejects a garbage id with 400 on all routes with `:id`', async () => {
    reached = 0;
    for (const [method, path] of [
      ['GET', '/items/not-a-uuid'],
      ['POST', '/items/not-a-uuid/act'],
    ]) {
      const response = await fetch(`${base}${path}`, { method });
      assert.equal(response.status, 400, `${method} ${path}`);
      assert.deepEqual(await response.json(), { error: 'id должен быть uuid' });
    }
    assert.equal(reached, 0);
  });

  it('leaves parameters with another name alone', async () => {
    reached = 0;
    const response = await fetch(`${base}/media/poster.jpg`);
    assert.equal(response.status, 200);
    assert.equal(reached, 1);
  });
});
