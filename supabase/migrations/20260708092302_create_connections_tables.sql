create table public.invite_links (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  code text unique not null,
  is_used boolean not null default false,
  used_by_id uuid references auth.users (id),
  created_at timestamptz not null default now()
);

alter table public.invite_links enable row level security;

-- Creation and activation both go through security-definer functions
-- (see invite_link_functions migration), so the only client-facing
-- capability here is reading your own invite links.
create policy "Owners can view their own invite links"
on public.invite_links for select
to authenticated
using (owner_id = auth.uid());

create table public.connections (
  id uuid primary key default gen_random_uuid(),
  user_a_id uuid not null references auth.users (id) on delete cascade,
  user_b_id uuid not null references auth.users (id) on delete cascade,
  method text not null check (method in ('invite_link', 'qr_code')),
  created_at timestamptz not null default now(),
  -- Canonical ordering avoids storing the same pair twice in either order
  -- and rules out a self-connection.
  constraint connections_ordered_pair check (user_a_id < user_b_id),
  constraint connections_unique_pair unique (user_a_id, user_b_id)
);

alter table public.connections enable row level security;

-- No insert/update policy: rows are only ever created by
-- activate_invite_link(), which runs as security definer.
create policy "Users can view their own connections"
on public.connections for select
to authenticated
using (auth.uid() = user_a_id or auth.uid() = user_b_id);
