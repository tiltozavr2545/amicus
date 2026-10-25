import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { guardLocalRequest } from './local_only.ts';

// A table of cases for the check that stands in front of the service_role
// key. The meaning of each "must reject" is in the header of local_only.ts;
// here we only verify that these cases really differ, rather than merely
// looking different.
describe('guardLocalRequest', () => {
  const loopback = { host: '127.0.0.1:5174', remoteAddress: '127.0.0.1' };

  it("lets the console's own request through Vite", () => {
    // The browser talks to Vite on 5173, which proxies to the API, keeping
    // Host.
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

  it('lets localhost through the same as 127.0.0.1', () => {
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

  it('lets the bracketed IPv6 loopback through', () => {
    assert.equal(
      guardLocalRequest({ host: '[::1]:5174', remoteAddress: '::1' }).ok,
      true,
    );
  });

  it('lets curl through: neither Origin nor Sec-Fetch-Site', () => {
    assert.equal(guardLocalRequest(loopback).ok, true);
  });

  it('lets a hand-typed address through (Sec-Fetch-Site: none)', () => {
    assert.equal(
      guardLocalRequest({ ...loopback, secFetchSite: 'none' }).ok,
      true,
    );
  });

  // The main case: a foreign domain with an A record of 127.0.0.1. To the
  // browser it is one origin with the API, no CORS arises, and the only
  // difference from a legitimate request is the name in Host.
  it('rejects DNS rebinding — a foreign domain in Host', () => {
    const verdict = guardLocalRequest({
      host: 'rebind.attacker.example:5174',
      origin: 'http://rebind.attacker.example:5174',
      secFetchSite: 'same-origin',
      remoteAddress: '127.0.0.1',
    });
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? '' : verdict.reason, /Host/);
  });

  it('rejects even when a foreign domain comes without a port', () => {
    assert.equal(guardLocalRequest({ host: 'attacker.example' }).ok, false);
  });

  it('rejects a cross-origin write from a foreign page', () => {
    const verdict = guardLocalRequest({
      ...loopback,
      origin: 'https://attacker.example',
      secFetchSite: 'cross-site',
    });
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? '' : verdict.reason, /Origin/);
  });

  it('rejects Origin: null (a page from data:/file:)', () => {
    assert.equal(guardLocalRequest({ ...loopback, origin: 'null' }).ok, false);
  });

  it('rejects Sec-Fetch-Site: same-site with a loopback Origin', () => {
    // Origin is loopback, Host is loopback — and it still isn't the console:
    // the browser itself said the request came from a page of another origin.
    const verdict = guardLocalRequest({
      ...loopback,
      origin: 'http://localhost:5173',
      secFetchSite: 'same-site',
    });
    assert.equal(verdict.ok, false);
    assert.match(verdict.ok ? '' : verdict.reason, /Sec-Fetch-Site/);
  });

  it('rejects a request without Host', () => {
    assert.equal(guardLocalRequest({}).ok, false);
  });

  it('rejects a non-loopback connection address', () => {
    assert.equal(
      guardLocalRequest({ ...loopback, remoteAddress: '192.168.1.14' }).ok,
      false,
    );
  });

  // `http://127.0.0.1.attacker.example` is a hostname that ENDS in a foreign
  // domain but starts like loopback. The check compares the whole hostname,
  // not a prefix.
  it('does not confuse loopback with a domain that looks like it', () => {
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
