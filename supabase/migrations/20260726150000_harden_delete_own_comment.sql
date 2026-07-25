-- Two hardening fixes in delete_own_comment(). Both are in the same function,
-- so they go in one migration rather than rewriting it twice.
--
-- 1) The ownership check failed *open*. `if v_author <> auth.uid()` is
--    three-valued: when auth.uid() is NULL the comparison is NULL, the `if`
--    does not fire, and control falls through to the delete. That is the only
--    authorization gate this RPC has — the DELETE policy on comments was
--    dropped in 20260725120000 precisely so every deletion goes through here —
--    so it should fail closed on anything it doesn't understand. Not reachable
--    with a Supabase-issued token today (the anon key carries role `anon`,
--    which has no EXECUTE, and a user token always has `sub`), which is exactly
--    why it is worth fixing before something else changes. `is distinct from`
--    treats NULL as "different", and an explicit guard rejects an
--    unauthenticated caller with a clear message, the way create_invite_link()
--    already does.
--
-- 2) A concurrent reply could be destroyed. The function asked "does this
--    comment have replies?" and then, in a *separate* statement, hard-deleted
--    it. Under READ COMMITTED a reply committed between the two is invisible to
--    the check but still caught by the FK's ON DELETE CASCADE: Alice deletes
--    her childless comment while Bob's reply to it is in flight, Bob's client
--    reports success, and the reply is gone. Taking the row FOR UPDATE before
--    the check closes the window — an inserting transaction has to take FOR KEY
--    SHARE on the parent for the FK, which FOR UPDATE conflicts with, so the
--    two are now serialised in both orders:
--      * insert commits first  -> our check sees the reply -> tombstone, kept;
--      * we commit first, having deleted -> the insert's FK check fails, and
--        Bob is told his reply did not land instead of silently losing it.
--
-- The childless-tombstone cleanup at the end is deliberately left unlocked. Its
-- own race (a reply appearing under a tombstone between the delete and the
-- cleanup) requires first slipping past the trigger's "cannot reply to a
-- deleted comment" — a window inside a window — while locking v_parent here
-- would introduce a real lock-ordering cycle against another session
-- cascade-deleting that same parent.

create or replace function public.delete_own_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_parent uuid;
  v_has_replies boolean;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- FOR UPDATE: see (2) above. Must be taken before the has-replies check.
  select author_id, parent_comment_id
    into v_author, v_parent
    from comments
   where id = p_comment_id
     for update;

  if not found then
    raise exception 'Comment not found';
  end if;
  if v_author is distinct from auth.uid() then
    raise exception 'Not your comment';
  end if;

  select exists (
    select 1 from comments where parent_comment_id = p_comment_id
  ) into v_has_replies;

  -- Has replies: tombstone it so those replies keep their context.
  if v_has_replies then
    update comments
       set deleted_at = now(),
           text = ''
     where id = p_comment_id;
    return;
  end if;

  delete from comments where id = p_comment_id;

  -- Was this the last reply under a tombstone? Then the tombstone has nothing
  -- left to hold together.
  if v_parent is not null then
    delete from comments
     where id = v_parent
       and deleted_at is not null
       and not exists (
         select 1 from comments r where r.parent_comment_id = v_parent
       );
  end if;
end;
$$;
