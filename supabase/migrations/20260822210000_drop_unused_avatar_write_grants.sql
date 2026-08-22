-- Два write-права на аватарку, которыми никто не пользуется.
--
-- 1. `grant update (name, avatar_path) on users` (20260820140000). Колонку
--    avatar_path клиент только читает — единственный, кто её пишет, это триггер
--    sync_avatar_path_from_profile_photos(), держащий её в синхроне с фото
--    наименьшей position (20260819240000). Проверяется одной командой:
--    `grep -rn avatar_path app/lib` — все попадания на чтение.
--
--    А грант живой, и RLS-политика на users говорит только «моя ли это строка»,
--    так что PATCH `{"avatar_path":"avatars/<чужой-uuid>/<их-фото>.jpg"}`
--    проходит. Значение держится, пока владелец сам не тронет свою галерею:
--    триггер висит на profile_photos, а не на users, и пересчитывать колонку
--    ему не с чего. До тех пор аватарка показывает чужое лицо в списке
--    знакомых, в ленте и в шапке каждого поста у всех, кто знаком с обоими.
--    20260822180000 закрыл ту же подмену через строку profile_photos; это
--    вторая дверь в ту же комнату.
--
--    Сузить грант можно только после того, как триггер перестанет ходить в
--    users правами вызывающего: он `security invoker`, и без гранта его UPDATE
--    падал бы с «permission denied for column avatar_path», забирая с собой
--    всякое добавление, удаление и переупорядочивание фотографий. Отсюда
--    первый шаг ниже — и он безопасен: RLS на profile_photos уже гарантирует,
--    что new/old.user_id — это сам вызывающий (INSERT- и DELETE-политики
--    прибивают user_id к auth.uid(), UPDATE-политики нет вовсе), так что
--    definer не расширяет того, что триггер может тронуть.
--
-- 2. Storage-политика "Users can update their own avatar" (20260707222025).
--    Замена файла в этом приложении всегда идёт как новый объект под свежим
--    client-minted путём плюс delete старого — overwrite не делает ни один
--    путь, и uploadTolerant специально не ставит `upsert: true`. Комментарий в
--    app/lib/shared/tolerant_upload.dart при этом утверждал, что UPDATE-политики
--    нет «ни для одного префикса»; для posts/ это правда, для avatars/ — нет,
--    и рассуждение, на которое сошлётся следующий читатель, было неверным ровно
--    наполовину. Политика уходит, комментарий поправлен вместе с ней.

create or replace function public.sync_avatar_path_from_profile_photos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.users
  set avatar_path = (
    select storage_path from public.profile_photos
    where user_id = coalesce(new.user_id, old.user_id)
    order by position asc
    limit 1
  )
  where id = coalesce(new.user_id, old.user_id);
  return coalesce(new, old);
end;
$$;

revoke update on public.users from authenticated;
grant update (name) on public.users to authenticated;

drop policy "Users can update their own avatar" on storage.objects;
