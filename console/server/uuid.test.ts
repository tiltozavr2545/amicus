import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { isUuid } from './uuid.ts';

describe('isUuid', () => {
  it('accepts a canonical uuid in any case', () => {
    for (const id of [
      'e5110c16-91e7-44ca-8075-348bca3efedd',
      'E5110C16-91E7-44CA-8075-348BCA3EFEDD',
      '00000000-0000-0000-0000-000000000000',
    ]) {
      assert.equal(isUuid(id), true, `rejected ${id}`);
    }
  });

  // All of this used to reach Postgres and come back as a 500 with the
  // driver's text instead of a 400.
  it('rejects what is not a uuid', () => {
    for (const bad of [
      '',
      'not-a-uuid',
      'null',
      'undefined',
      '../../etc/passwd',
      'e5110c16-91e7-44ca-8075-348bca3efed', // one character short
      'e5110c16-91e7-44ca-8075-348bca3efeddd', // one character long
      'e5110c16_91e7_44ca_8075_348bca3efedd', // underscores instead of hyphens
      'g5110c16-91e7-44ca-8075-348bca3efedd', // invalid digit
      ' e5110c16-91e7-44ca-8075-348bca3efedd', // leading space
      'e5110c16-91e7-44ca-8075-348bca3efedd ', // trailing space
      '{e5110c16-91e7-44ca-8075-348bca3efedd}', // curly braces
      'urn:uuid:e5110c16-91e7-44ca-8075-348bca3efedd',
    ]) {
      assert.equal(isUuid(bad), false, `accepted ${JSON.stringify(bad)}`);
    }
  });

  // The request body arrives as parsed JSON, so the value can be anything —
  // that is what the `typeof x !== 'string'` checks, which this function
  // replaced, used to trip over.
  it('rejects a non-string', () => {
    for (const bad of [undefined, null, 42, true, {}, [], ['a']]) {
      assert.equal(isUuid(bad), false, `accepted ${JSON.stringify(bad)}`);
    }
  });

  // Anchors `^…$`, not "contains": without them an id with a suffix would
  // pass through.
  it('does not accept a uuid with a suffix', () => {
    const id = 'e5110c16-91e7-44ca-8075-348bca3efedd';
    assert.equal(isUuid(`${id}\nDROP`), false);
    assert.equal(isUuid(`x${id}`), false);
    assert.equal(isUuid(`${id}/..`), false);
  });
});
