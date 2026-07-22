-- Mute (one-directional) and block (mutual) a connection without breaking
-- the Connection itself. Both are separate tables because they differ in
-- visibility semantics: mute hides the muted author's posts from the muter
-- only, block hides posts in both directions.

create table public.muted_users (
  muter_id uuid not null references public.users (id) on delete cascade,
  muted_id uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (muter_id, muted_id),
  constraint muted_users_no_self_mute check (muter_id <> muted_id)
);

alter table public.muted_users enable row level security;

create policy "Users manage their own mutes"
on public.muted_users for all
to authenticated
using (muter_id = auth.uid())
with check (muter_id = auth.uid());

revoke all on public.muted_users from anon;

create table public.blocked_users (
  blocker_id uuid not null references public.users (id) on delete cascade,
  blocked_id uuid not null references public.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  constraint blocked_users_no_self_block check (blocker_id <> blocked_id)
);

alter table public.blocked_users enable row level security;

create policy "Users manage their own blocks"
on public.blocked_users for all
to authenticated
using (blocker_id = auth.uid())
with check (blocker_id = auth.uid());

revoke all on public.blocked_users from anon;

drop policy "Posts are viewable by author and their connections" on public.posts;

create policy "Posts are viewable by author and their connections"
on public.posts for select
to authenticated
using (
  author_id = auth.uid()
  or (
    exists (
      select 1 from connections c
      where (c.user_a_id = auth.uid() and c.user_b_id = posts.author_id)
         or (c.user_b_id = auth.uid() and c.user_a_id = posts.author_id)
    )
    and not exists (
      select 1 from muted_users m
      where m.muter_id = auth.uid() and m.muted_id = posts.author_id
    )
    and not exists (
      select 1 from blocked_users b
      where (b.blocker_id = auth.uid() and b.blocked_id = posts.author_id)
         or (b.blocker_id = posts.author_id and b.blocked_id = auth.uid())
    )
  )
);
