-- Amicus news account (future-development.md, "Новостной аккаунт Amicus"):
-- posts announcements/updates, visible to everyone, without taking a slot in
-- anyone's real Connections.
--
-- Deliberately not a Connection row auto-created for every user. That would
-- mean re-deriving the exclusion in every place that reads `connections`
-- (contacts list, invite flow) and would leave it mutable/blockable through
-- the normal UI like any other Connection — exactly the kind of duplicated
-- rule the second audit already burned us on (see is_author_visible() in
-- 20260726120000). Instead the account is a single hardcoded exception inside
-- the one rule everything else already defers to: is_author_visible() and its
-- bulk form visible_author_ids(). No Connection row means it can't appear in
-- a connections list built from that table, and no mute/block row can matter
-- because the visibility check short-circuits before it would look.
--
-- is_system_account() holds the id in exactly one place, same spirit as
-- "менять только в этой функции" for is_author_visible itself.
create or replace function public.is_system_account(p_id uuid)
returns boolean
language sql
immutable
as $$
  select p_id = 'e5110c16-91e7-44ca-8075-348bca3efedd'::uuid;
$$;

-- Takes an arbitrary id, not tied to auth.uid() — same rule as
-- is_blocked_pair(): only ever called from inside another security definer
-- function, never granted to PostgREST roles directly.
revoke execute on function public.is_system_account(uuid) from public, anon, authenticated;

create or replace function public.is_author_visible(p_author uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_author = auth.uid()
      or public.is_system_account(p_author)
      or (
        exists (
          select 1 from connections c
          where (c.user_a_id = auth.uid() and c.user_b_id = p_author)
             or (c.user_b_id = auth.uid() and c.user_a_id = p_author)
        )
        and not exists (
          select 1 from muted_users m
          where m.muter_id = auth.uid() and m.muted_id = p_author
        )
        and not public.is_blocked_pair(auth.uid(), p_author)
      );
$$;

create or replace function public.visible_author_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid()
  union
  select id from public.users where public.is_system_account(id)
  union
  select other.id
    from (
      select case when c.user_a_id = auth.uid() then c.user_b_id else c.user_a_id end as id
        from connections c
       where c.user_a_id = auth.uid() or c.user_b_id = auth.uid()
    ) other
   where public.is_author_visible(other.id);
$$;
