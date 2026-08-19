-- Found while manually testing 20260819240000 on a live account: a user who
-- set their avatar through the *old* single-photo uploadAvatar() flow (path
-- avatars/<uid>/avatar_<millis>.<ext>, or even older seed data at
-- avatars/<uid>/avatar.jpg — see the removed uploadAvatar() in
-- profile_repository.dart, before profile_photos existed) never got a
-- profile_photos row for that file, since the table didn't exist yet at
-- upload time. Two consequences: the photo was invisible in the new gallery/
-- viewer, and the moment the user added their first *new* photo,
-- sync_avatar_path_from_profile_photos() (20260819240000) recomputed
-- users.avatar_path from profile_photos alone — which didn't contain the old
-- file — so the original avatar silently vanished, replaced by whatever was
-- just added. Reproduced against a live row: b944d75e-…-62685dd0b026's
-- avatars/…/avatar_1784038165416.jpg, uploaded 2026-07-14, orphaned the
-- instant a new photo was added on 2026-08-19.
--
-- "Legacy" is identified structurally, not by one specific filename pattern
-- (there turned out to be two): every file under avatars/<uid>/ whose own
-- filename is *not* itself a UUID — the only shape [profilePhotoPath] ever
-- writes for the new gallery. Anything else under that prefix necessarily
-- predates the gallery.
--
-- Fix: link every such object still sitting in Storage back into
-- profile_photos, appended after whatever's already there (never as
-- position 0) — an account that already added new photos keeps its current
-- avatar_path untouched, the legacy photo just becomes visible/reorderable
-- again instead of staying orphaned. An account that never touched the new
-- feature has an empty profile_photos, so this is its only (and therefore
-- position-0) row — no visible change, avatar_path already pointed at this
-- same path. row_number() rather than a flat max()+1 so this stays correct
-- even if more than one legacy file somehow survived for the same user (the
-- old flow best-effort deleted the previous one on every upload, so in
-- practice there's at most one).
with legacy as (
  select
    o.name as storage_path,
    ((regexp_match(o.name, '^avatars/([0-9a-f-]{36})/'))[1])::uuid as user_id
  from storage.objects o
  where o.bucket_id = 'media'
    and o.name ~ '^avatars/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
    and o.name !~ '^avatars/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]+$'
    and not exists (
      select 1 from public.profile_photos pp where pp.storage_path = o.name
    )
),
positioned as (
  select
    l.user_id,
    l.storage_path,
    coalesce(
      (select max(pp.position) from public.profile_photos pp where pp.user_id = l.user_id),
      -1
    ) + row_number() over (partition by l.user_id order by l.storage_path) as position
  from legacy l
  where exists (select 1 from public.users u where u.id = l.user_id)
)
insert into public.profile_photos (user_id, position, storage_path)
select user_id, position, storage_path from positioned;
