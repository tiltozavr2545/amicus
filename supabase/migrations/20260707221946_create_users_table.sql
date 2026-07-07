-- users: public profile linked 1:1 to auth.users
create table public.users (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null,
  avatar_url text,
  created_at timestamptz not null default now()
);

alter table public.users enable row level security;

-- Anyone authenticated can see any profile (needed to show author name/avatar
-- on posts from Connections).
create policy "Profiles are viewable by authenticated users"
on public.users for select
to authenticated
using (true);

-- A user can only create/edit their own profile row.
create policy "Users can insert their own profile"
on public.users for insert
to authenticated
with check (auth.uid() = id);

create policy "Users can update their own profile"
on public.users for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);
