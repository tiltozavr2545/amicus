-- References public.users (not auth.users) so PostgREST can embed the
-- author's profile in a single query: .select('*, author:users(name)').
create table public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.users (id) on delete cascade,
  text text,
  image_path text,
  created_at timestamptz not null default now(),
  constraint posts_has_content check (text is not null or image_path is not null)
);

alter table public.posts enable row level security;

create policy "Posts are viewable by author and their connections"
on public.posts for select
to authenticated
using (
  author_id = auth.uid()
  or exists (
    select 1 from connections c
    where (c.user_a_id = auth.uid() and c.user_b_id = posts.author_id)
       or (c.user_b_id = auth.uid() and c.user_a_id = posts.author_id)
  )
);

create policy "Users can create their own posts"
on public.posts for insert
to authenticated
with check (author_id = auth.uid());
