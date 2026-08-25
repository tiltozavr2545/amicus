-- Добавление фотографий в галерею перестаёт считать `position` на клиенте.
--
-- `addPhotos` (profile_repository.dart) берёт максимальную позицию из СПИСКА,
-- который ему передал экран, прибавляет единицу и нумерует новые строки от неё.
-- Список этот — закэшированное значение `_profilePhotosProvider`, и он бывает
-- отставшим ровно в тех случаях, ради которых вся остальная машинерия и
-- заведена: `.timeout()` перестаёт ждать, не отменяя запрос, поэтому
-- предыдущее добавление могло закоммититься уже после того, как экран показал
-- ошибку; плюс второе устройство.
--
-- Дальше отставший список целится в занятые позиции и упирается в
-- `profile_photos_user_position_key`. Погасить этот конфликт `upsert` не может:
-- его арбитр — `(user_id, storage_path)` (20260819240000), а пути у новых
-- файлов свои, так что конфликт по position не разрешается, а падает, унося с
-- собой весь батч. Тот же класс — «две половины одной записи считаются на
-- клиенте» — 20260820150000 уже вычистила из ПЕРЕСТАНОВКИ, заведя
-- reorder_profile_photos(); до добавления она не дошла.
--
-- Позицию теперь выдаёт сервер, в той же транзакции, что и вставку, — то есть
-- ровно из того состояния таблицы, в которое строки и лягут. Отставший клиент
-- перестаёт быть проблемой, потому что его мнение о позициях больше не
-- спрашивают.
--
-- ПЛОТНОСТЬ. Новые строки нумеруются подряд от `max(position) + 1`, а
-- повторно присланные (ретрай) отсеиваются ДО нумерации, а не гасятся
-- `on conflict` после неё. Иначе дубликат «съедал» бы номер и в нумерации
-- появлялись бы дыры на каждом ретрае; `position` здесь `smallint`, и хотя до
-- 32767 так просто не дойти, дырявая нумерация — это лишний вопрос у
-- следующего читателя. `on conflict do nothing` всё равно оставлен: он ловит
-- гонку двух одновременных вызовов, которую `not exists` в одном запросе не
-- видит.
--
-- ПРЕФИКС. `security definer` проносит вставку мимо INSERT-политики
-- "Users can add their own profile photos" (20260822180000), поэтому её
-- условие повторено здесь — дословно то же, что и там. Это не вторая копия
-- правила, а второй вызов одного условия на втором пути записи, ровно как у
-- set_post_media()/create_post_with_media() для post_media.
--
-- Лимит в 80 остаётся на триггере enforce_profile_photos_limit(): он висит на
-- таблице и одинаково ловит оба пути записи, включая ретрай (20260820120000).
--
-- Прямой INSERT в profile_photos НЕ закрывается: по нему ходят сборки в Play
-- (min(app_build) = 41), и снять грант — сломать им добавление фотографий.
-- Тот же довод, что в 20260823120000.

create or replace function public.append_profile_photos(p_items jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Photo list must be an array' using errcode = 'PT422';
  end if;

  if jsonb_array_length(p_items) = 0 then
    return;
  end if;

  if exists (
    select 1
      from jsonb_array_elements(p_items) item
     where coalesce(item.value ->> 'storage_path', '')
           not like 'avatars/' || auth.uid()::text || '/%'
  ) then
    raise exception 'Photo path outside your own prefix' using errcode = 'PT422';
  end if;

  select coalesce(max(pp.position) + 1, 0) into v_next
    from profile_photos pp
   where pp.user_id = auth.uid();

  insert into profile_photos (user_id, position, storage_path)
  select
    auth.uid(),
    (v_next + row_number() over (order by fresh.idx) - 1)::smallint,
    fresh.storage_path
  from (
    select item.idx as idx, item.value ->> 'storage_path' as storage_path
      from jsonb_array_elements(p_items) with ordinality as item(value, idx)
     where not exists (
       select 1 from profile_photos pp
        where pp.user_id = auth.uid()
          and pp.storage_path = item.value ->> 'storage_path'
     )
  ) fresh
  on conflict (user_id, storage_path) do nothing;
end;
$$;

-- Аргумент про самого вызывающего: `user_id` внутри всегда `auth.uid()`, пути
-- прибиты к его собственному префиксу. См. «Каждая функция в public — эндпоинт
-- PostgREST» в CLAUDE.md.
revoke execute on function public.append_profile_photos(jsonb) from public, anon;
grant execute on function public.append_profile_photos(jsonb) to authenticated;
