import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  authBanDuration,
  defaultAuthBanDays,
  defaultWriteBanDays,
  parseBanDays,
  writeBanUntil,
} from './ban_duration.ts';

describe('parseBanDays', () => {
  it('принимает число', () => {
    assert.deepEqual(parseBanDays(3), { ok: true, days: 3 });
  });

  it('принимает число строкой — форма присылает именно строку', () => {
    assert.deepEqual(parseBanDays('30'), { ok: true, days: 30 });
  });

  it('пустой срок оставляет выбор дефолта вызывающему', () => {
    for (const empty of [undefined, null, '']) {
      assert.deepEqual(parseBanDays(empty), { ok: true, days: null });
    }
  });

  // Раньше это доходило до `new Date(NaN).toISOString()` и превращалось в 500
  // с текстом «Invalid time value».
  it('отказывает на нечисле вместо падения дальше по стеку', () => {
    for (const bad of ['неделя', {}, [], 'NaN', '7 суток']) {
      assert.equal(
        parseBanDays(bad).ok,
        false,
        `принял ${JSON.stringify(bad)}`,
      );
    }
  });

  // Худший случай был тихим: бан «до вчера» применяется и сразу же не
  // действует, а консоль показывает наказание как назначенное.
  it('отказывает на нуле и отрицательном', () => {
    for (const bad of [0, -1, '-30', '0']) {
      assert.equal(
        parseBanDays(bad).ok,
        false,
        `принял ${JSON.stringify(bad)}`,
      );
    }
  });

  it('отказывает на Infinity', () => {
    assert.equal(parseBanDays(Number.POSITIVE_INFINITY).ok, false);
    assert.equal(parseBanDays('1e400').ok, false);
  });
});

describe('writeBanUntil', () => {
  const now = Date.UTC(2026, 8, 24, 12, 0, 0);

  it('отсчитывает срок от переданного момента', () => {
    assert.equal(writeBanUntil(2, now), '2026-09-26T12:00:00.000Z');
  });

  it('без срока берёт дефолт', () => {
    assert.equal(
      writeBanUntil(null, now),
      writeBanUntil(defaultWriteBanDays, now),
    );
  });

  it('всегда отдаёт момент в будущем относительно now', () => {
    assert.ok(new Date(writeBanUntil(1, now)).getTime() > now);
  });
});

describe('authBanDuration', () => {
  it('переводит сутки в часы, как того ждёт GoTrue', () => {
    assert.equal(authBanDuration(1), '24h');
    assert.equal(authBanDuration(0.5), '12h');
  });

  it('без срока берёт дефолт «навсегда»', () => {
    assert.equal(authBanDuration(null), authBanDuration(defaultAuthBanDays));
  });

  it('никогда не отдаёт 0h — это значило бы «не забанен»', () => {
    assert.equal(authBanDuration(0.001), '1h');
  });

  it('упирается в потолок вместо неразбираемой строки', () => {
    assert.equal(authBanDuration(1e9), '876000h');
    assert.match(authBanDuration(1e9), /^\d+h$/);
  });
});
