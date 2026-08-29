-- =====================================================================
-- Storage: фотографии поста наследуют видимость САМОГО поста, а не автора.
--
-- Находка симуляции сразу после наката 20260826180000: знакомый автора,
-- в комнату не позванный, открывал файл фотографии поста, адресованного
-- ТОЛЬКО в комнату. Строку `post_media` он при этом не видел, и сам пост
-- тоже — не пускала RLS, — а файл открывался.
--
-- Причина в том, что путь объекта — `posts/<author_id>/<токены>/<файл>` —
-- знает только АВТОРА, и до комнат этого хватало: все посты автора жили в
-- общей ленте, и «видно автора» означало «видно и его фотографии». С
-- комнатами это перестало быть правдой: у одного и того же автора теперь
-- бывают посты, которые часть его знакомых видеть не должна, а путь их
-- никак не различает.
--
-- Поэтому политика больше не идёт от пути к автору, а идёт от пути к ПОСТУ —
-- через `post_media`, где лежат оба поля пути (сам файл и постер видео), —
-- и спрашивает у него ровно то же правило, что и все остальные:
-- `is_post_visible()`. Одна копия правила, не вторая.
--
-- `media_path_in_my_rooms()`, заведённая вчерашней миграцией, этим
-- поглощается целиком (ветвь комнаты — частный случай) и дропается, чтобы
-- не остаться второй, более узкой копией того же вопроса.
--
-- Своя ветвь у автора остаётся первой и намеренно НЕ требует строки в
-- `post_media`: клиент заливает файлы ДО того, как появляется пост
-- (см. `createPost` в feed_repository.dart), и без неё автор не смог бы
-- открыть только что залитое. Для всех остальных отсутствие строки —
-- это и есть правильный ответ «нет такого поста»: брошенный черновик
-- никому не виден, его уносит `reap_orphaned_media()`.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.post_media_path_visible(p_path text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1
      from post_media pm
     where (pm.storage_path = p_path or pm.poster_path = p_path)
       and public.is_post_visible(pm.post_id)
  );
$function$;

drop policy "Post photos are viewable by connections or by room members" on storage.objects;

create policy "Post photos follow their post's visibility"
  on storage.objects
  for select
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'posts'::text)
    AND (((storage.foldername(name))[2] = (auth.uid())::text)
         OR public.post_media_path_visible(name))));

drop function if exists public.media_path_in_my_rooms(text);

revoke execute on function public.post_media_path_visible(p_path text) from public, anon, authenticated;
grant execute on function public.post_media_path_visible(p_path text) to authenticated;

do $$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'media_path_in_my_rooms'
  ) then
    raise exception 'media_path_in_my_rooms() осталась в схеме';
  end if;

  if not exists (
    select 1 from pg_policy
     where polrelid = 'storage.objects'::regclass
       and polname = 'Post photos follow their post''s visibility'
  ) then
    raise exception 'Политика фотографий постов не заменилась';
  end if;
end;
$$;
