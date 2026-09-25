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
  it('принимает то, что сам же и выдал', () => {
    assert.equal(stagedName(stagedRef(NAME)), NAME);
  });

  it('не признаёт путь в бакет своим', () => {
    for (const path of [
      'posts/11111111-2222-3333-4444-555555555555/a.jpg',
      'avatars/x/y.jpg',
      '',
    ]) {
      assert.equal(isStaged(path), false, `признал ${path}`);
      assert.equal(stagedName(path), null);
    }
  });

  // Единственная проверка между строкой из запроса и `resolve()` по файловой
  // системе, поэтому проверяется она, а не читается.
  it('отбивает выход за каталог', () => {
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
        `пропустил ${JSON.stringify(evil)}`,
      );
    }
  });

  it('требует и uuid, и расширение', () => {
    for (const bad of [
      '11111111-2222-3333-4444-555555555555',
      '11111111-2222-3333-4444-555555555555.',
      '11111111-2222-3333-4444-555555555555.toolong',
      'not-a-uuid.jpg',
      `${NAME}.jpg`,
      NAME.toUpperCase(),
    ]) {
      assert.equal(stagedName(stagedRef(bad)), null, `пропустил ${bad}`);
    }
  });
});

describe('extensionForMime / mimeForExtension', () => {
  // Таблица читается в обе стороны, и на этом держится `contentType` при
  // заливке staged-файла в бакет: расширение на диске — единственное, что от
  // типа остаётся к моменту публикации.
  it('ходит по кругу для всего, что принимает бакет', () => {
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
      assert.match(ext, /^[a-z0-9]{2,5}$/, `${mime} дал негодное ${ext}`);
      assert.equal(mimeForExtension(`f.${ext}`), mime);
    }
  });

  it('не выдумывает тип для незнакомого расширения', () => {
    assert.equal(mimeForExtension('f.exe'), null);
    assert.equal(mimeForExtension('f.bin'), null);
    assert.equal(mimeForExtension('noextension'), null);
  });
});
