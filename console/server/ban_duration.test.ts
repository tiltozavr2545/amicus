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
  it('accepts a number', () => {
    assert.deepEqual(parseBanDays(3), { ok: true, days: 3 });
  });

  it('accepts a number as a string — the form sends a string', () => {
    assert.deepEqual(parseBanDays('30'), { ok: true, days: 30 });
  });

  it('an empty duration leaves the default choice to the caller', () => {
    for (const empty of [undefined, null, '']) {
      assert.deepEqual(parseBanDays(empty), { ok: true, days: null });
    }
  });

  // This used to reach `new Date(NaN).toISOString()` and turn into a 500 with
  // the text "Invalid time value".
  it('rejects a non-number instead of failing further down the stack', () => {
    for (const bad of ['неделя', {}, [], 'NaN', '7 суток']) {
      assert.equal(
        parseBanDays(bad).ok,
        false,
        `accepted ${JSON.stringify(bad)}`,
      );
    }
  });

  // The worst case was silent: a ban "until yesterday" is applied and is
  // immediately void, while the console shows the penalty as imposed.
  it('rejects zero and negative', () => {
    for (const bad of [0, -1, '-30', '0']) {
      assert.equal(
        parseBanDays(bad).ok,
        false,
        `accepted ${JSON.stringify(bad)}`,
      );
    }
  });

  it('rejects Infinity', () => {
    assert.equal(parseBanDays(Number.POSITIVE_INFINITY).ok, false);
    assert.equal(parseBanDays('1e400').ok, false);
  });

  // A finite but absurd number reached `new Date(...)` outside the range, and
  // `writeBanUntil` failed with exactly the `RangeError` this module was
  // created for. `authBanDuration` was covered against this by its own clamp;
  // the write ban had no clamp.
  it('rejects a finite but impossible duration', () => {
    for (const bad of [1e8, 1e9, '1e12', 36_501]) {
      assert.equal(parseBanDays(bad).ok, false, `accepted ${bad}`);
    }
  });

  it('accepts a hundred years — the upper bound inclusive', () => {
    assert.deepEqual(parseBanDays(36_500), { ok: true, days: 36_500 });
  });
});

describe('writeBanUntil', () => {
  const now = Date.UTC(2026, 8, 24, 12, 0, 0);

  it('counts the duration from the given moment', () => {
    assert.equal(writeBanUntil(2, now), '2026-09-26T12:00:00.000Z');
  });

  it('falls back to the default without a duration', () => {
    assert.equal(
      writeBanUntil(null, now),
      writeBanUntil(defaultWriteBanDays, now),
    );
  });

  it('always returns a moment in the future relative to now', () => {
    assert.ok(new Date(writeBanUntil(1, now)).getTime() > now);
  });

  // Everything `parseBanDays` lets through must parse into a date. Nobody
  // used to check this, and the upper edge of the range was exactly the place
  // where it didn't parse.
  it('parses into a date for everything that passes parsing', () => {
    for (const days of [1, 7, 365, 36_500]) {
      const parsed = parseBanDays(days);
      assert.equal(parsed.ok, true);
      assert.match(
        writeBanUntil(days, now),
        /^\d{4}-\d{2}-\d{2}T/,
        `${days} days did not turn into a date`,
      );
    }
  });
});

describe('authBanDuration', () => {
  it('converts days to hours, as GoTrue expects', () => {
    assert.equal(authBanDuration(1), '24h');
    assert.equal(authBanDuration(0.5), '12h');
  });

  it('falls back to the "forever" default without a duration', () => {
    assert.equal(authBanDuration(null), authBanDuration(defaultAuthBanDays));
  });

  it('never returns 0h — that would mean "not banned"', () => {
    assert.equal(authBanDuration(0.001), '1h');
  });

  it('hits the ceiling instead of an unparseable string', () => {
    assert.equal(authBanDuration(1e9), '876000h');
    assert.match(authBanDuration(1e9), /^\d+h$/);
  });
});
