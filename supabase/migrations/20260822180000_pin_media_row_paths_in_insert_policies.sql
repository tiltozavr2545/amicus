-- INSERT-политики post_media и profile_photos начинают проверять префикс пути.
--
-- 20260822170000 закрыл это только в set_post_media(), то есть на пути
-- РЕДАКТИРОВАНИЯ поста. Путь СОЗДАНИЯ (createPost) пишет строки post_media
-- обычным INSERT'ом через политику ниже, а она спрашивала только «мой ли это
-- пост» и про storage_path не говорила ничего. У profile_photos так было с
-- самого 20260819240000, и там ещё хуже: триггер
-- sync_avatar_path_from_profile_photos() переносит storage_path строки с
-- наименьшей position в users.avatar_path, то есть чужой путь оттуда
-- расходится по всем экранам, которые рисуют аватарку.
--
-- Что это давало. avatar_path Connection'а приезжает клиенту как есть —
-- fetchFriends его и запрашивает, чтобы нарисовать список знакомых, — так что
-- чужой путь известен, угадывать uuid не надо. Вставив строку с ним в
-- собственный пост или в собственную галерею, можно показать чужую фотографию
-- как свою. Утечки байтов при этом нет: SELECT-политика storage по-прежнему
-- решает, кому отдать объект, и тот, кто не имел права его видеть, получит
-- пустой слот. Ломается другое — авторство, и инвариант «строка медиа
-- указывает на объект своего же автора», который до сих пор держался ровно на
-- одном из двух путей записи.
--
-- Условие дословно то же, что уже стоит в set_post_media() и в
-- storage-политике на INSERT: `posts/<auth.uid()>/…` и `avatars/<auth.uid()>/…`.
-- В post_media сравнивать с auth.uid(), а не с author_id поста, корректно —
-- политика тут же требует p.author_id = auth.uid(), так что это одно и то же
-- значение. uuid в текстовом виде не содержит ни `%`, ни `_`, поэтому
-- LIKE-шаблон безопасен без экранирования.

-- Сначала убедиться, что накат ничего не разотрёт: до этой миграции такие
-- строки было можно завести, и политика на них не распространяется задним
-- числом — их надо увидеть и починить руками, а не узнать о них потом.
do $$
declare
  v_bad bigint;
begin
  select count(*) into v_bad
    from public.post_media pm
    join public.posts p on p.id = pm.post_id
   where pm.storage_path not like 'posts/' || p.author_id::text || '/%'
      or (pm.poster_path is not null
          and pm.poster_path not like 'posts/' || p.author_id::text || '/%');

  if v_bad > 0 then
    raise exception
      'post_media: % row(s) sit outside posts/<author_id>/…; fix them before applying this migration',
      v_bad;
  end if;

  select count(*) into v_bad
    from public.profile_photos pp
   where pp.storage_path not like 'avatars/' || pp.user_id::text || '/%';

  if v_bad > 0 then
    raise exception
      'profile_photos: % row(s) sit outside avatars/<user_id>/…; fix them before applying this migration',
      v_bad;
  end if;
end
$$;

drop policy "Users can attach media to their own posts" on public.post_media;

create policy "Users can attach media to their own posts"
on public.post_media for insert
to authenticated
with check (
  created_at = now()
  and exists (
    select 1 from public.posts p
    where p.id = post_media.post_id
      and p.author_id = auth.uid()
  )
  and post_media.storage_path like 'posts/' || auth.uid()::text || '/%'
  and (
    post_media.poster_path is null
    or post_media.poster_path like 'posts/' || auth.uid()::text || '/%'
  )
);

drop policy "Users can add their own profile photos" on public.profile_photos;

create policy "Users can add their own profile photos"
on public.profile_photos for insert
to authenticated
with check (
  user_id = auth.uid()
  and created_at = now()
  and storage_path like 'avatars/' || auth.uid()::text || '/%'
);
