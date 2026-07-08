-- Both functions run as security definer so they can write to
-- invite_links/connections despite those tables having no insert/update
-- policies for regular users — all writes are funneled through here so the
-- "mark used" + "create connection" pair stays atomic.

create or replace function public.create_invite_link()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  v_code := encode(gen_random_bytes(5), 'hex');

  insert into invite_links (owner_id, code)
  values (auth.uid(), v_code);

  return v_code;
end;
$$;

grant execute on function public.create_invite_link() to authenticated;

create or replace function public.activate_invite_link(p_code text)
returns table (owner_id uuid, owner_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_invite invite_links%rowtype;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_invite
  from invite_links
  where code = p_code
  for update;

  if not found then
    raise exception 'Invite code not found';
  end if;

  if v_invite.is_used then
    raise exception 'Invite code already used';
  end if;

  if v_invite.owner_id = auth.uid() then
    raise exception 'Cannot activate your own invite link';
  end if;

  insert into connections (user_a_id, user_b_id, method)
  values (least(v_invite.owner_id, auth.uid()), greatest(v_invite.owner_id, auth.uid()), 'invite_link')
  on conflict (user_a_id, user_b_id) do nothing;

  update invite_links
  set is_used = true, used_by_id = auth.uid()
  where id = v_invite.id;

  return query
  select u.id, u.name from users u where u.id = v_invite.owner_id;
end;
$$;

grant execute on function public.activate_invite_link(text) to authenticated;
