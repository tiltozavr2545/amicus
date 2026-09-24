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
  return { ok: true, days };
}

/// Момент, до которого запрещено писать.
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
