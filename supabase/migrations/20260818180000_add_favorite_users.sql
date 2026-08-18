-- Favoriting a Connection: purely personal, one-directional, no effect on the
-- other side (unlike mute/block, which change what they see too) — so no
-- confirmation dialog needed client-side, same reasoning as unmute/unblock.
-- Same shape as muted_users/blocked_users (20260715120000): new table, no
-- anon grants from the start, RLS scoped to the caller's own rows.
--
-- Not enforced here that favorite_id is actually a Connection of user_id —
-- muted_users/blocked_users don't enforce that either (the constraint lives
-- only in which buttons the client shows, on the "Знакомства" list). Kept
-- consistent rather than tightening just this one table.
create table public.favorite_users (
  user_id uuid not null references public.users (id) on delete cascade,
  favorite_id uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, favorite_id),
  constraint favorite_users_no_self_favorite check (user_id <> favorite_id)
);

alter table public.favorite_users enable row level security;

create policy "Users manage their own favorites"
on public.favorite_users for all
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

revoke all on public.favorite_users from anon;
