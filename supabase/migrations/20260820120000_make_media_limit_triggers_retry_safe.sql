-- Лимиты 20 медиа на пост и 80 фото профиля ломали повторную отправку.
--
-- Оба backstop-триггера (20260819200000, 20260819240000) — `BEFORE INSERT`, а
-- этот момент в Postgres наступает ДО арбитража `ON CONFLICT`: строка,
-- которую `ON CONFLICT DO NOTHING` в итоге отбросит как дубликат, всё равно
-- проходит через триггер. Пока строк меньше лимита, это незаметно — счётчик
-- просто не дорастает. Ровно на лимите — ломается.
--
-- Сценарий целиком клиентский и штатный. `.timeout()` в Dart не отменяет
-- запрос, а лишь перестаёт его ждать (см. 20260818120000), поэтому пост с 20
-- медиа может закоммититься уже после того, как экран показал ошибку. Ретрай —
-- то, ради чего заведены `client_token` и `(post_id, storage_path)` — шлёт те
-- же 20 строк заново. Первая же из них попадает в триггер, тот видит
-- `count(*) = 20 >= 20` и кидает `post_media_limit_exceeded`. И так каждый
-- следующий раз: пост на самом деле давно опубликован, а пользователь навсегда
-- заперт на «не удалось опубликовать». Тот же тупик у 80-го фото профиля.
--
-- Чинится в триггере, а не в клиенте: клиент делает ровно то, что должен, и
-- любой другой повтор той же вставки (не только наш) обязан быть no-op.
-- Проверка «такой элемент уже есть» идёт по тому же уникальному ключу, по
-- которому `ON CONFLICT` и разрешает конфликт — то есть триггер пропускает
-- именно те строки, которые всё равно будут отброшены, и ни одной другой.
--
-- Лимит от этого не слабеет: пропускается только повтор УЖЕ существующего
-- элемента, а он в счётчик уже включён. Подделанный запрос с 21-м НОВЫМ
-- элементом дубликатом не является и упирается в ту же проверку, что и раньше.
--
-- `security definer` по-прежнему не нужен — обе функции читают ту же таблицу,
-- в которую пишет вызывающий, и его собственная политика уже даёт ему
-- видимость этих строк (см. рассуждение в 20260819200000).

create or replace function public.enforce_post_media_limit()
returns trigger
language plpgsql
as $$
begin
  -- Повтор уже существующего элемента: `ON CONFLICT (post_id, storage_path)`
  -- отбросит эту строку сам, а в лимит она уже посчитана.
  if exists (
    select 1 from public.post_media
    where post_id = new.post_id
      and storage_path = new.storage_path
  ) then
    return new;
  end if;

  if (select count(*) from public.post_media where post_id = new.post_id) >= 20 then
    raise exception 'post_media_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create or replace function public.enforce_profile_photos_limit()
returns trigger
language plpgsql
as $$
begin
  -- То же самое по `(user_id, storage_path)`.
  if exists (
    select 1 from public.profile_photos
    where user_id = new.user_id
      and storage_path = new.storage_path
  ) then
    return new;
  end if;

  if (select count(*) from public.profile_photos where user_id = new.user_id) >= 80 then
    raise exception 'profile_photos_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
