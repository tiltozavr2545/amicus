-- Nested comments (replies), one level deep.
--
-- The MVP schema never actually had parent_comment_id — it lived only in the
-- data-model draft in the brief — so it is added here, together with two
-- companions:
--
--   parent_comment_id  the *thread root* this comment belongs to. null for a
--                      root comment. Depth is capped at one level: a comment
--                      whose parent is itself a reply is rejected.
--   reply_to_id        who the reply is addressed to (the root itself, or a
--                      sibling reply). Display only — it drives the "in reply
--                      to <name>" label, which is what makes a flattened
--                      thread readable. Never affects nesting.
--   deleted_at         tombstone marker, see delete_own_comment() below.
--
-- Storing the root separately from the addressee is what keeps the read path
-- flat: one query, group by parent_comment_id, no recursion.

alter table public.comments
  add column parent_comment_id uuid references public.comments (id) on delete cascade,
  add column reply_to_id uuid references public.comments (id) on delete set null,
  add column deleted_at timestamptz;

create index comments_parent_comment_id_idx on public.comments (parent_comment_id);

-- Depth and consistency can't be expressed as a check constraint (they depend
-- on another row), so they go in a trigger. SECURITY DEFINER because the
-- lookups below must see the parent row even when the caller can't: comments'
-- SELECT policy is scoped to the caller's connections, and an RLS-filtered
-- lookup that finds nothing would read as "parent is a root" and let a crafted
-- API call slip past the depth cap. Same reasoning as is_blocked_pair().
create or replace function public.enforce_comment_reply_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  parent record;
  addressee record;
begin
  if new.parent_comment_id is null then
    if new.reply_to_id is not null then
      raise exception 'Only a reply can address another comment';
    end if;
    return new;
  end if;

  select post_id, parent_comment_id, deleted_at
    into parent
    from comments
   where id = new.parent_comment_id;

  if not found then
    raise exception 'Parent comment not found';
  end if;
  if parent.post_id <> new.post_id then
    raise exception 'Parent comment belongs to a different post';
  end if;
  if parent.parent_comment_id is not null then
    raise exception 'Replies cannot be nested more than one level deep';
  end if;
  if parent.deleted_at is not null then
    raise exception 'Cannot reply to a deleted comment';
  end if;

  -- The addressee has to be inside this very thread: either the root or one of
  -- its replies. Anything else would render a label pointing at an unrelated
  -- (possibly invisible) comment.
  if new.reply_to_id is not null then
    select parent_comment_id, deleted_at
      into addressee
      from comments
     where id = new.reply_to_id;

    if not found then
      raise exception 'Addressed comment not found';
    end if;
    if new.reply_to_id <> new.parent_comment_id
       and addressee.parent_comment_id is distinct from new.parent_comment_id then
      raise exception 'Addressed comment belongs to a different thread';
    end if;
    if addressee.deleted_at is not null then
      raise exception 'Cannot reply to a deleted comment';
    end if;
  end if;

  return new;
end;
$$;

create trigger comments_enforce_reply_rules
before insert on public.comments
for each row execute function public.enforce_comment_reply_rules();

-- Deleting a comment that has replies would take other people's replies down
-- with it (the FK above cascades), so such a comment is tombstoned instead:
-- the row survives to keep the thread readable, the text is actually erased.
-- A comment with no replies is still deleted for real — a tombstone is only
-- worth keeping where it holds a thread together.
--
-- This is a function rather than a policy pair because the hard/soft decision
-- has to be made server-side and atomically, and because the alternative — an
-- UPDATE policy on comments — would hand clients the ability to edit comment
-- text, which is deliberately not a feature yet. The DELETE policy from
-- 20260710113710 is dropped for the same reason: with it in place a client
-- could bypass this function and hard-delete a root, cascading away replies
-- written by others.
drop policy "Users can delete their own comments" on public.comments;

create or replace function public.delete_own_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_has_replies boolean;
begin
  select author_id into v_author from comments where id = p_comment_id;
  if v_author is null then
    raise exception 'Comment not found';
  end if;
  if v_author <> auth.uid() then
    raise exception 'Not your comment';
  end if;

  select exists (
    select 1 from comments where parent_comment_id = p_comment_id
  ) into v_has_replies;

  if v_has_replies then
    update comments
       set deleted_at = now(),
           text = ''
     where id = p_comment_id;
  else
    delete from comments where id = p_comment_id;
  end if;
end;
$$;

revoke execute on function public.delete_own_comment(uuid) from public, anon;
grant execute on function public.delete_own_comment(uuid) to authenticated;

-- A tombstone must stay unwritable-around: the INSERT policy already pins
-- author_id to the caller, and the trigger above rejects replies to a deleted
-- parent, so there is no path that revives one.
