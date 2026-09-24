import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { guardLocalRequest } from './local_only.ts';

// Таблица случаев для проверки, которая стоит перед service_role-ключом.
// Смысл каждого «должен отказать» — в шапке local_only.ts; здесь только то,
// что эти случаи реально различаются, а не выглядят различающимися.
describe('guardLocalRequest', () => {
  const loopback = { host: '127.0.0.1:5174', remoteAddress: '127.0.0.1' };

  it('пускает запрос самой консоли через Vite', () => {
    // Браузер говорит с Vite на 5173, тот проксирует в API, сохраняя Host.
    assert.deepEqual(
      guardLocalRequest({
        host: '127.0.0.1:5173',
        origin: 'http://127.0.0.1:5173',
        secFetchSite: 'same-origin',
        remoteAddress: '127.0.0.1',
      }),
      { ok: true },
    );
  });

  it('пускает localhost так же, как 127.0.0.1', () => {
    assert.equal(
      guardLocalRequest({
        host: 'localhost:5173',
        origin: 'http://localhost:5173',
        secFetchSite: 'same-origin',
        remoteAddress: '::ffff:127.0.0.1',
      }).ok,
      true,
    );
  });

  it('пускает IPv6-петлю в скобках', () => {
    assert.equal(
      guardLocalRequest({ host: '[::1]:5174', remoteAddress: '::1' }).ok,
      true,
    );
  });

  it('пускает curl: ни Origin, ни Sec-Fetch-Site', () => {
    assert.equal(guardLocalRequest(loopback).ok, true);
  });

  it('пускает набранный руками адрес (Sec-Fetch-Site: none)', () => {
    assert.equal(
      guardLocalRequest({ ...loopback, secFetchSite: 'none' }).ok,
      true,
    );
  });

  // Главный случай: чужой домен с A-записью 127.0.0.1. Для браузера это один
  // origin с API, никакого CORS не возникает, и единственное отличие от
  // законного запроса — имя в Host.
  it('отказывает при DNS rebinding — чужой домен в Host', () => {
    const verdict = guardLocalRequest({
      host: 'rebind.attacker.example:5174',
      origin: 'http://rebind.attacker.example:5174',
      secFetchSite: 'same-origin',
      remoteAddress: '127.0.0.1',
    });
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? '' : verdict.reason, /Host/);
  });

  it('отказывает, даже если чужой домен притворяется без порта', () => {
    assert.equal(guardLocalRequest({ host: 'attacker.example' }).ok, false);
  });

  it('отказывает cross-origin записи с чужой страницы', () => {
    const verdict = guardLocalRequest({
      ...loopback,
      origin: 'https://attacker.example',
      secFetchSite: 'cross-site',
    });
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? '' : verdict.reason, /Origin/);
  });

  it('отказывает Origin: null (страница из data:/file:)', () => {
    assert.equal(guardLocalRequest({ ...loopback, origin: 'null' }).ok, false);
  });

  it('отказывает на Sec-Fetch-Site: same-site при петлевом Origin', () => {
    // Origin петлевой, Host петлевой — и всё равно это не консоль: браузер
    // сам сказал, что запрос пришёл со страницы другого origin.
    const verdict = guardLocalRequest({
      ...loopback,
      origin: 'http://localhost:5173',
      secFetchSite: 'same-site',
    });
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? '' : verdict.reason, /Sec-Fetch-Site/);
  });

  it('отказывает запросу без Host', () => {
    assert.equal(guardLocalRequest({}).ok, false);
  });

  it('отказывает непетлевому адресу соединения', () => {
    assert.equal(
      guardLocalRequest({ ...loopback, remoteAddress: '192.168.1.14' }).ok,
      false,
    );
  });

  // `http://127.0.0.1.attacker.example` — хостнейм, который ЗАКАНЧИВАЕТСЯ на
  // чужой домен, но начинается как петля. Проверка сравнивает хостнейм
  // целиком, а не по префиксу.
  it('не путает петлю с доменом, который на неё похож', () => {
    assert.equal(
      guardLocalRequest({ host: '127.0.0.1.attacker.example:5174' }).ok,
      false,
    );
    assert.equal(
      guardLocalRequest({ host: 'localhost.attacker.example' }).ok,
      false,
    );
    assert.equal(
      guardLocalRequest({
        ...loopback,
        origin: 'http://localhost.attacker.example',
      }).ok,
      false,
    );
  });
});
