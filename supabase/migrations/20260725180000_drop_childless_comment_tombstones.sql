-- A tombstone (0.10.0) exists for exactly one reason: to keep a branch readable
-- after the comment it hangs from is deleted. Delete the last reply under one
-- and that reason is gone — but the row stayed behind, invisible on the comments
-- screen (the client drops a childless tombstone) yet still counted by the
-- feed's comment counter. Found on a device: a post whose comments screen was
-- empty still showed "1".
--
-- So the tombstone now follows its last reply out. The counter also stops
-- counting tombstones at all (see feed_repository.dart) — the two changes cover
-- different holes: this one keeps the table from accumulating rows nobody can
-- ever see, the client-side filter also covers a tombstone that still has
-- replies, which is displayed as a placeholder but is not content either.

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
  select author_id, parent_comment_id
    into v_author, v_parent
    from comments
   where id = p_comment_id;

  if not found then
    raise exception 'Comment not found';
  end if;
  if v_author <> auth.uid() then
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

-- One-off sweep for the tombstones already stranded by the old behaviour.
delete from public.comments c
 where c.deleted_at is not null
   and not exists (
     select 1 from public.comments r where r.parent_comment_id = c.id
   );
