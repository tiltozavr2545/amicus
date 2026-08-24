-- Системный аккаунт наконец виден целиком, а не наполовину.
--
-- Исключение «системный аккаунт видно всем» заводили постепенно и в четырёх
-- местах: SELECT-политика `users` (20260818160000), `is_author_visible()` и
-- `visible_author_ids()` (20260818150000), storage-политика фотографий постов
-- (через visible_author_ids(), 20260726180000). До двух оставшихся мест оно не
-- дошло:
--   * storage-политика на `avatars/…` (20260712120000) — «себе или Connection»;
--   * SELECT-политика `profile_photos` (20260819240000) — то же правило.
-- Системный аккаунт не является ничьим Connection по построению, так что обе
-- отвечают «нельзя» вообще всем.
--
-- Наружу это выходит через пасхалку: шесть переключений темы открывают
-- FriendProfileScreen системного аккаунта (theme_toggle_switch.dart), а этот
-- экран рисует аватарку и по тапу открывает галерею. Имя и фотографии постов
-- на нём грузятся, аватарка и галерея — нет.
--
-- Сегодня это не видно: у аккаунта `avatar_path is null` и ноль строк
-- profile_photos, то есть показывать пока нечего. Дыра сработает ровно в тот
-- момент, когда аккаунту поставят аватар — и сработает молча, серой иконкой
-- человечка без единой ошибки где-либо. Чинится до того, а не после.
--
-- Это не пятая копия правила видимости: обе политики спрашивают ту же самую
-- `is_system_account()`, которая после 20260822220000 читает единственный
-- источник — `system_account_ids()`. Оба места уже выданы `authenticated`.
--
-- В avatars-политике сравнение идёт по тексту, а не через `::uuid`, — так же,
-- как в её же ветке про connections. У объекта `avatars/.emptyFolderPlaceholder`
-- второго сегмента нет вовсе, и приводить NULL к uuid только ради сравнения
-- незачем.

drop policy "Avatars are viewable by the user and their connections" on storage.objects;

create policy "Avatars are viewable by the user, their connections, and the system account"
on storage.objects for select
to authenticated
using (
  bucket_id = 'media'
  and (storage.foldername(name))[1] = 'avatars'
  and (
    (storage.foldername(name))[2] = auth.uid()::text
    or (storage.foldername(name))[2] in (
      select s::text from public.system_account_ids() s
    )
    or exists (
      select 1 from public.connections c
      where (c.user_a_id = auth.uid() and c.user_b_id::text = (storage.foldername(name))[2])
         or (c.user_b_id = auth.uid() and c.user_a_id::text = (storage.foldername(name))[2])
    )
  )
);

drop policy "Profile photos are viewable by the user and their connections" on public.profile_photos;

create policy "Profile photos are viewable by the user, their connections, and the system account"
on public.profile_photos for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_system_account(user_id)
  or public.is_connected_to_caller(user_id)
);
