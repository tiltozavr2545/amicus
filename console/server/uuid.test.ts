import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { isUuid } from './uuid.ts';

describe('isUuid', () => {
  it('принимает канонический uuid в любом регистре', () => {
    for (const id of [
      'e5110c16-91e7-44ca-8075-348bca3efedd',
      'E5110C16-91E7-44CA-8075-348BCA3EFEDD',
      '00000000-0000-0000-0000-000000000000',
    ]) {
      assert.equal(isUuid(id), true, `отверг ${id}`);
    }
  });

  // Всё это доезжало до Postgres и возвращалось как 500 с текстом драйвера
  // вместо 400.
  it('отбивает то, что uuid не является', () => {
    for (const bad of [
      '',
      'not-a-uuid',
      'null',
      'undefined',
      '../../etc/passwd',
      'e5110c16-91e7-44ca-8075-348bca3efed', // на символ короче
      'e5110c16-91e7-44ca-8075-348bca3efeddd', // на символ длиннее
      'e5110c16_91e7_44ca_8075_348bca3efedd', // подчёркивания вместо дефисов
      'g5110c16-91e7-44ca-8075-348bca3efedd', // недопустимая цифра
      ' e5110c16-91e7-44ca-8075-348bca3efedd', // ведущий пробел
      'e5110c16-91e7-44ca-8075-348bca3efedd ', // хвостовой пробел
      '{e5110c16-91e7-44ca-8075-348bca3efedd}', // фигурные скобки
      'urn:uuid:e5110c16-91e7-44ca-8075-348bca3efedd',
    ]) {
      assert.equal(isUuid(bad), false, `принял ${JSON.stringify(bad)}`);
    }
  });

  // Тело запроса приходит разобранным JSON, то есть значением может оказаться
  // что угодно — на этом и ловились `typeof x !== 'string'`-проверки, которые
  // эта функция заменила.
  it('отбивает не-строку', () => {
    for (const bad of [undefined, null, 42, true, {}, [], ['a']]) {
      assert.equal(isUuid(bad), false, `принял ${JSON.stringify(bad)}`);
    }
  });

  // Якоря `^…$`, а не «содержит»: без них id с довеском проезжал бы дальше.
  it('не принимает uuid с довеском', () => {
    const id = 'e5110c16-91e7-44ca-8075-348bca3efedd';
    assert.equal(isUuid(`${id}\nDROP`), false);
    assert.equal(isUuid(`x${id}`), false);
    assert.equal(isUuid(`${id}/..`), false);
  });
});
