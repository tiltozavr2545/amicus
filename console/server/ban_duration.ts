/// Сколько длится наказание, по тому, что прислала консоль.
///
/// Отдельный модуль, а не три строки в обработчике, ровно по одной причине:
/// это арифметика над данными из формы, у неё есть граничные случаи, и их
/// надо проверять тестом. Пока она жила внутри `/moderation/ban`, проверить
/// её было нечем, и оба случая ниже дошли до прода.
///
///   * `Number("неделя")` — это NaN, а `new Date(NaN).toISOString()` бросает
///     RangeError. Модератор видел 500 и «Invalid time value» вместо ответа,
///     что срок задан неверно.
///   * отрицательное число проходило молча и было хуже: `write_banned_until`
///     в прошлом — это бан, снятый в тот же миг. Консоль показывала
///     применённое наказание, которого нет.

/// Сутки запрета писать по умолчанию, если срок не прислали.
export const defaultWriteBanDays = 7;

/// Срок бана входа по умолчанию — «навсегда» в понятных GoTrue единицах.
export const defaultAuthBanDays = 3650;

/// Потолок в часах (сто лет): `ban_duration` уезжает в GoTrue строкой, и
/// `1e21h` он уже не разбирает.
const maxAuthBanHours = 876_000;

/// Те же сто лет, но сутками — и это потолок на ВХОДЕ, общий для обоих сроков.
///
/// Он тут не для симметрии. `Number.isFinite` пропускает `1e9`, а `1e9` суток
/// — это `8.64e16` миллисекунд, то есть за пределом диапазона `Date`, и
/// `writeBanUntil` падал на `toISOString()` тем самым `RangeError: Invalid
/// time value`, ради которого этот модуль и заведён (см. заголовок).
/// `authBanDuration` от этого прикрыт — он клампится о `maxAuthBanHours`, и
/// это проверено тестом на `1e9`, — а у запрета писать клампа не было,
/// потому что не было и общего места, где его поставить.
///
/// Поставлено отказом, а не клампом, и это разница по смыслу: «навсегда» —
/// законное намерение для бана входа, и у него для этого есть свой дефолт
/// ([defaultAuthBanDays]). А `days: 1e9` в запросе — не «навсегда», а мусор,
/// и молча превратить его в наказание на сто лет хуже, чем сказать, что
/// число не годится.
const maxBanDays = 36_500;

export type BanDays =
  | { ok: true; days: number | null }
  | { ok: false; error: string };

/// `null` означает «срок не прислали» — вызывающий подставит свой дефолт.
export function parseBanDays(raw: unknown): BanDays {
  if (raw === undefined || raw === null || raw === '')
    return { ok: true, days: null };
  const days = Number(raw);
  if (!Number.isFinite(days) || days <= 0) {
    return { ok: false, error: 'days: положительное число суток' };
  }
  if (days > maxBanDays) {
    return { ok: false, error: `days: не больше ${maxBanDays} суток` };
  }
  return { ok: true, days };
}

/// Момент, до которого запрещено писать.
///
/// Верхняя граница снята с входа ([maxBanDays]), а не проверяется здесь: этой
/// функции достаётся уже разобранное число, и второй потолок в двух местах
/// разошёлся бы с первым.
export function writeBanUntil(days: number | null, now: number): string {
  return new Date(now + (days ?? defaultWriteBanDays) * 864e5).toISOString();
}

/// `ban_duration` для GoTrue.
export function authBanDuration(days: number | null): string {
  const hours = Math.min(
    maxAuthBanHours,
    Math.max(1, Math.round((days ?? defaultAuthBanDays) * 24)),
  );
  return `${hours}h`;
}
