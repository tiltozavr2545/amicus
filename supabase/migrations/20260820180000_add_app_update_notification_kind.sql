-- 20260820170000 started enqueueing 'app_update' rows but missed that
-- notification_outbox.kind is constrained to a fixed list (last widened in
-- 20260819170000) — every system-account post was failing the insert.

alter table public.notification_outbox
  drop constraint notification_outbox_kind_check,
  add constraint notification_outbox_kind_check
    check (kind in ('new_post', 'inactive_week', 'digest', 'post_comment', 'comment_reply', 'app_update'));
