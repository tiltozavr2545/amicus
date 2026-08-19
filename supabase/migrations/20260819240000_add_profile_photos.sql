-- До 80 фото профиля на пользователя (как в Telegram) вместо одного
-- avatar_path, который можно было только целиком заменить. Одна строка —
-- одно фото; position задаёт порядок в галерее, тем же неплотным способом,
-- что и post_media.position (20260819200000) — при reorder клиент переписывает
-- позиции всех строк разом (delete+insert), дыры не образуются, но и не
-- гарантируются отсутствующими.
--
-- users.avatar_path остаётся единственным источником, который читает весь
-- остальной клиент (лента, список знакомых, экран заблокированных,
-- friend_profile_screen) — трогать все эти места ради галереи не нужно.
-- Вместо этого триггер держит его в синхроне с "верхним" фото (наименьший
-- position) на каждой мутации profile_photos, так что смена аватарки —
-- то же самое, что и раньше, просто с точки зрения клиента: сам aватар на
-- экране профиля показывает position 0, добавление/удаление/reorder фото
-- пересчитывают его автоматически.
create table public.profile_photos (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users (id) on delete cascade,
  position smallint not null,
  storage_path text not null,
  created_at timestamptz not null default now(),
  constraint profile_photos_user_position_key unique (user_id, position),
  -- Идемпотентность batch-вставки при ретрае, тот же приём, что и у
  -- post_media_post_storage_path_key.
  constraint profile_photos_user_storage_path_key unique (user_id, storage_path)
);

alter table public.profile_photos enable row level security;

-- Та же видимость, что и у самой аватарки (20260712120000): себе или
-- Connection, БЕЗ учёта mute/block. Это сознательно другое правило, чем
-- is_author_visible() у постов — см. комментарий в 20260726130000: блок не
-- рвёт Connection, и заблокированный должен продолжать видеть аватар на
-- экране «Заблокированные», где блок и снимают. is_connected_to_caller()
-- (20260819160000) — готовая однонаправленная обёртка ровно для этого случая.
create policy "Profile photos are viewable by the user and their connections"
on public.profile_photos for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_connected_to_caller(user_id)
);

create policy "Users can add their own profile photos"
on public.profile_photos for insert
to authenticated
with check (
  user_id = auth.uid()
  and created_at = now()
);

create policy "Users can delete their own profile photos"
on public.profile_photos for delete
to authenticated
using (user_id = auth.uid());

-- Нет UPDATE-политики намеренно, тот же выбор, что и у post_media: reorder —
-- всегда delete+insert строк (storage-объект не трогается, та же
-- storage_path переиспользуется под новым id/position), никогда update на
-- месте.

revoke insert on public.profile_photos from authenticated;
grant insert (user_id, position, storage_path, created_at)
  on public.profile_photos to authenticated;

-- Лимит 80 — backstop-триггер, тот же паттерн, что и enforce_post_media_limit
-- (CHECK не умеет cross-row); основной гейт — клиент.
create or replace function public.enforce_profile_photos_limit()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.profile_photos where user_id = new.user_id) >= 80 then
    raise exception 'profile_photos_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger profile_photos_enforce_limit_before_insert
before insert on public.profile_photos
for each row execute function public.enforce_profile_photos_limit();

-- Держит users.avatar_path в синхроне с фото наименьшей position. Не
-- security definer: и INSERT, и DELETE на profile_photos уже гарантируют
-- user_id = auth.uid(), а users уже грантует authenticated UPDATE на
-- avatar_path для собственной строки (profile_repository.dart исторически
-- писал в неё напрямую) — RLS на users пропускает этот UPDATE тем же
-- путём, что и любой другой self-scoped запрос. При каскадном удалении
-- аккаунта (delete_own_account(), 20260819230000) строка users к моменту,
-- когда этот триггер срабатывает на дочерних profile_photos, уже удалена
-- каскадом выше по цепочке — UPDATE матчит 0 строк, безопасный no-op.
create or replace function public.sync_avatar_path_from_profile_photos()
returns trigger
language plpgsql
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

create trigger profile_photos_sync_avatar_path
after insert or update or delete on public.profile_photos
for each row execute function public.sync_avatar_path_from_profile_photos();
