import assert from 'node:assert/strict';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { after, before, describe, it } from 'node:test';
import express from 'express';
import { localOnly } from './local_only.ts';

// Отдельно от табличного теста: тот проверяет решение, этот — что решение
// вообще участвует в обработке запроса. `server/index.ts` целиком поднять
// нельзя (он требует service_role-ключ на импорте и слушает фиксированный
// порт), поэтому здесь собирается такая же связка на эфемерном порту: сначала
// `localOnly`, потом всё остальное. Если middleware когда-нибудь уедет ниже
// разбора тела или потеряется при правке `index.ts`, падать будет здесь.
describe('localOnly в express', () => {
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
      // Не `resolve` напрямую: колбэк `listen` объявлен как
      // `(error?: Error) => void`, и передать туда `resolve` — значит
      // пообещать, что ошибка сойдёт за `void`.
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

  it('пропускает обычный запрос консоли', async () => {
    const response = await fetch(`${base}/api/probe`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ hello: 'world' }),
    });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { ok: true });
    assert.equal(bodyParsed, true);
  });

  it('отбивает 403 на чужой Origin и НЕ доходит до обработчика', async () => {
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
    // Ключевая половина: обработчик не вызвался, то есть побочного эффекта не
    // произошло — а не «произошёл, но ответ не показали».
    assert.equal(bodyParsed, false);
  });

  // Через `fetch` этот случай не поставить: `Host` — forbidden header name, и
  // undici его молча не отправляет, из-за чего запрос уходил с настоящим
  // хостом и тест «проходил» проверку, которую не проверял. Поэтому здесь
  // сырой `node:http`, где заголовок ставится как есть — ровно как его
  // поставит браузер, разрешивший чужой домен в 127.0.0.1.
  it('отбивает 403 на подменённый Host (DNS rebinding)', async () => {
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
