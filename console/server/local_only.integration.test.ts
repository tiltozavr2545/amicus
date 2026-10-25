import assert from 'node:assert/strict';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, describe, it } from 'node:test';
import express from 'express';
import { localOnly } from './local_only.ts';

// Separate from the table test: that one checks the decision, this one checks
// that the decision takes part in request handling at all. `server/index.ts`
// can't be brought up as a whole (it requires the service_role key on import
// and listens on a fixed port), so the same chain is assembled here on an
// ephemeral port: `localOnly` first, then everything else. If the middleware
// ever moves below body parsing or gets lost in an edit of `index.ts`, this is
// where it will fail.
describe('localOnly in express', () => {
  let base: string;
  let server: ReturnType<express.Express['listen']>;
  let bodyParsed = false;

  before(async () => {
    const app = express();
    app.use(localOnly);
    app.use(express.json());
    app.post('/api/probe', (req, res) => {
      bodyParsed = req.body !== undefined;
      res.json({ ok: true });
    });
    await new Promise<void>((resolve) => {
      // Not `resolve` directly: the `listen` callback is declared as
      // `(error?: Error) => void`, and passing `resolve` there means promising
      // that an error can pass for `void`.
      server = app.listen(0, '127.0.0.1', () => resolve());
    });
    const { port } = server.address() as AddressInfo;
    base = `http://127.0.0.1:${port}`;
  });

  after(async () => {
    await new Promise<void>((resolve, reject) => {
      server.close((error) => (error ? reject(error) : resolve()));
    });
  });

  it('lets an ordinary console request through', async () => {
    const response = await fetch(`${base}/api/probe`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hello: 'world' }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
    assert.equal(bodyParsed, true);
  });

  it('rejects a foreign Origin with 403 and does NOT reach the handler', async () => {
    bodyParsed = false;
    const response = await fetch(`${base}/api/probe`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Origin: 'https://attacker.example',
      },
      body: JSON.stringify({ hello: 'world' }),
    });
    assert.equal(response.status, 403);
    // The key half: the handler wasn't called, so the side effect didn't
    // happen — rather than "it happened, but the response wasn't shown".
    assert.equal(bodyParsed, false);
  });

  // This case can't be set up through `fetch`: `Host` is a forbidden header
  // name, and undici silently doesn't send it, so the request went out with
  // the real host and the test "passed" a check it wasn't testing. Hence raw
  // `node:http` here, where the header is set as is — exactly as a browser
  // that resolved a foreign domain to 127.0.0.1 would set it.
  it('rejects a spoofed Host with 403 (DNS rebinding)', async () => {
    bodyParsed = false;
    const { port } = server.address() as AddressInfo;
    const status = await new Promise<number>((resolve, reject) => {
      const request = http.request(
        {
          host: '127.0.0.1',
          port,
          method: 'POST',
          path: '/api/probe',
          headers: {
            'Content-Type': 'application/json',
            Host: 'rebind.attacker.example',
          },
        },
        (response) => {
          response.resume();
          response.on('end', () => resolve(response.statusCode ?? 0));
        },
      );
      request.on('error', reject);
      request.end(JSON.stringify({ hello: 'world' }));
    });
    assert.equal(status, 403);
    assert.equal(bodyParsed, false);
  });
});
