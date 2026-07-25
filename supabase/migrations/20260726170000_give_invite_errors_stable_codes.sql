-- The Connections screen was the last place still printing a raw exception
-- message at the user: 0.9.1 replaced every `"...: $e"` with a generic
-- localized string, but `on PostgrestException catch (e) { ... = e.message }`
-- in _activate() survived, because there the message is genuinely useful —
-- "Invite code already used" is exactly what the user needs to be told.
--
-- The trouble is that the same channel carries everything else the database
-- might say. A statement timeout, a constraint violation, a pool error — all
-- arrive as PostgrestException too, and the user gets shown raw text naming
-- tables and constraints. And the useful three are hardcoded English, so the
-- Russian locale showed them in English anyway.
--
-- So the errors get identity separate from their prose: a stable SQLSTATE the
-- client can switch on, with the wording moved into the app's ARB files. The
-- messages stay here for logs.
--
-- The codes follow PostgREST's PTxyz convention, which also gives each one a
-- sensible HTTP status instead of the 500 an unrecognised SQLSTATE class would
-- produce. 'Not authenticated' deliberately keeps the default P0001: it is
-- unreachable from a screen that only exists behind a session, so it falls
-- through to the client's generic message like any other unexpected failure.

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
    raise exception 'Invite code not found' using errcode = 'PT404';
  end if;

  if v_invite.is_used then
    raise exception 'Invite code already used' using errcode = 'PT409';
  end if;

  if v_invite.owner_id = auth.uid() then
    raise exception 'Cannot activate your own invite link' using errcode = 'PT422';
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
