import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import {
  extensionForMime,
  isStaged,
  mimeForExtension,
  stagedName,
  stagedRef,
} from './news.ts';

const NAME = '11111111-2222-3333-4444-555555555555.jpg';

describe('stagedName', () => {
  it('accepts what it issued itself', () => {
    assert.equal(stagedName(stagedRef(NAME)), NAME);
  });

  it('does not recognise a bucket path as its own', () => {
    for (const path of [
      'posts/11111111-2222-3333-4444-555555555555/a.jpg',
      'avatars/x/y.jpg',
      '',
    ]) {
      assert.equal(isStaged(path), false, `recognised ${path}`);
      assert.equal(stagedName(path), null);
    }
  });

  // The only check between a string from the request and `resolve()` on the
  // file system, so it gets tested rather than merely read.
  it('rejects escaping the directory', () => {
    for (const evil of [
      '../../etc/passwd',
      '..%2F..%2Fetc',
      'a/../../b.jpg',
      '/etc/hosts',
      `${NAME}/../../x`,
      `../${NAME}`,
      '.',
      '..',
    ]) {
      assert.equal(
        stagedName(stagedRef(evil)),
        null,
        `let through ${JSON.stringify(evil)}`,
      );
    }
  });

  it('requires both a uuid and an extension', () => {
    for (const bad of [
      '11111111-2222-3333-4444-555555555555',
      '11111111-2222-3333-4444-555555555555.',
      '11111111-2222-3333-4444-555555555555.toolong',
      'not-a-uuid.jpg',
      `${NAME}.jpg`,
      NAME.toUpperCase(),
    ]) {
      assert.equal(stagedName(stagedRef(bad)), null, `let through ${bad}`);
    }
  });
});

describe('extensionForMime / mimeForExtension', () => {
  // The table is read in both directions, and `contentType` relies on that
  // when a staged file is uploaded to the bucket: the extension on disk is the
  // only thing left of the type by the time of publication.
  it('round-trips for everything the bucket accepts', () => {
    for (const mime of [
      'image/jpeg',
      'image/png',
      'image/webp',
      'image/heic',
      'image/heif',
      'video/mp4',
      'video/quicktime',
      'video/x-m4v',
      'video/3gpp',
      'video/webm',
      'video/x-matroska',
    ]) {
      const ext = extensionForMime(mime);
      assert.match(ext, /^[a-z0-9]{2,5}$/, `${mime} gave an invalid ${ext}`);
      assert.equal(mimeForExtension(`f.${ext}`), mime);
    }
  });

  it('does not invent a type for an unknown extension', () => {
    assert.equal(mimeForExtension('f.exe'), null);
    assert.equal(mimeForExtension('f.bin'), null);
    assert.equal(mimeForExtension('noextension'), null);
  });
});
