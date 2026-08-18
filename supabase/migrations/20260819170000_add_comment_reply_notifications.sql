-- Push notifications for comment activity — closes the "Push-уведомления о
-- комментариях" item of future-development.md (posts/digest/inactive-week
-- already shipped in 0.12.0, see 20260818190000).
--
-- Two events, one trigger, same outbox as posts (20260818190000):
--   post_comment   someone commented under a post I own.
--   comment_reply  someone replied to a comment of mine.
--
-- A reply is *also* a comment under the post, so both events can fire off the
-- same inserted row. When they'd both land on the same person (I wrote the
-- comment that got replied to, on my own post) only comment_reply fires — the
-- more specific "X replied to you" beats the generic "X commented on your
-- post" for the exact same row, and sending both would just be the same
-- event twice.
--
-- No digest tier here unlike posts: comments happen at a much lower volume
-- per user, so batching would only add latency without solving a real spam
-- problem yet. Revisit if that stops being true.

alter table public.notification_outbox
  drop constraint notification_outbox_kind_check,
  add constraint notification_outbox_kind_check
    check (kind in ('new_post', 'inactive_week', 'digest', 'post_comment', 'comment_reply'));

-- SECURITY DEFINER so the lookups (post owner, reply target's author) see the
-- real rows regardless of the commenter's own visibility — same reasoning as
-- enqueue_post_notifications(). The mute/block check is deliberately from the
-- *recipient's* point of view (has_muted(recipient, commenter),
-- is_blocked_pair(recipient, commenter)), not the commenter's: RLS on the
-- comments INSERT only ever verified visibility looking outward from the
-- commenter (can they see the post/parent/addressee), which is silent about
-- whether the recipient has muted *them* — mute isn't symmetric, so that half
-- of the check still needs to happen here, not assumed from the fact the
-- insert was allowed at all.
create or replace function public.enqueue_comment_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_commenter_name text;
  v_post_owner uuid;
  v_reply_target_author uuid;
begin
  select name into v_commenter_name from users where id = new.author_id;
  select author_id into v_post_owner from posts where id = new.post_id;

  if new.reply_to_id is not null then
    select author_id into v_reply_target_author from comments where id = new.reply_to_id;

    if v_reply_target_author is not null
       and v_reply_target_author <> new.author_id
       and not public.is_system_account(v_reply_target_author)
       and not public.has_muted(v_reply_target_author, new.author_id)
       and not public.is_blocked_pair(v_reply_target_author, new.author_id)
    then
      insert into notification_outbox (user_id, kind, payload)
      values (
        v_reply_target_author,
        'comment_reply',
        jsonb_build_object(
          'author_name', v_commenter_name,
          'post_id', new.post_id,
          'comment_id', new.id
        )
      );
    end if;

    -- Same recipient would just get the post_comment version of the same
    -- event too — the mute/block predicate above is identical for that
    -- recipient either way, so skipping here can't hide a case the guard
    -- below would otherwise have caught.
    if v_reply_target_author = v_post_owner then
      return new;
    end if;
  end if;

  if v_post_owner is not null
     and v_post_owner <> new.author_id
     and not public.is_system_account(v_post_owner)
     and not public.has_muted(v_post_owner, new.author_id)
     and not public.is_blocked_pair(v_post_owner, new.author_id)
  then
    insert into notification_outbox (user_id, kind, payload)
    values (
      v_post_owner,
      'post_comment',
      jsonb_build_object(
        'author_name', v_commenter_name,
        'post_id', new.post_id,
        'comment_id', new.id
      )
    );
  end if;

  return new;
end;
$$;

create trigger on_comment_created_enqueue_notifications
  after insert on public.comments
  for each row execute function public.enqueue_comment_notifications();
