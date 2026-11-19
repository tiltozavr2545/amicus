-- Only the sender reads per-device outcomes. Hashes keep the registration
-- tokens themselves out of the queue and survive a retry after a partial send.
alter table public.notification_outbox
  add column settled_deliveries jsonb not null default '{}'::jsonb,
  add column delivery_attempts smallint not null default 0,
  add column next_attempt_at timestamptz,
  add column failed_at timestamptz,
  add column last_delivery_error text;

drop index public.notification_outbox_unsent_idx;
create index notification_outbox_unsent_idx on public.notification_outbox (created_at)
  where sent_at is null and failed_at is null;

create function public.claim_notification_deliveries(p_limit integer)
returns setof public.notification_outbox
language sql
set search_path to 'public', 'pg_temp'
as $function$
  update public.notification_outbox o
     set claimed_at = now()
   where o.id in (
     select n.id
       from public.notification_outbox n
      where n.sent_at is null and n.failed_at is null
        and (n.next_attempt_at is null or n.next_attempt_at <= now())
        and (n.claimed_at is null or n.claimed_at < now() - interval '5 minutes')
      order by n.created_at, n.id
      limit p_limit
      for update skip locked
   )
  returning o.*;
$function$;

-- Leave enough time for the worker to finish FCM requests and return its
-- outcome to pg_net. The sender stops starting new requests after 45 seconds.
select cron.schedule(
  'drain-notification-outbox',
  '* * * * *',
  $job$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_function_url'),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_service_role_key'),
      'x-send-push-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'send_push_shared_secret'),
      'Content-Type', 'application/json'
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 70000
  );
  $job$
);

-- Keep the previous sender's response shape during deployment.
create or replace function public.claim_notification_outbox(p_limit integer)
returns table(id uuid, user_id uuid, kind text, payload jsonb)
language sql
security definer
set search_path to 'public', 'pg_temp'
as $function$
  select n.id, n.user_id, n.kind, n.payload
    from public.claim_notification_deliveries(p_limit) n;
$function$;

-- Apply a whole batch in one request. The lease timestamp prevents a late
-- worker from overwriting the result after another worker claimed the row.
create function public.finish_notification_deliveries(p_results jsonb)
returns integer
language sql
set search_path to 'public', 'pg_temp'
as $function$
  with finished as (
    update public.notification_outbox n
       set sent_at = case when r.next_attempt_at is null and not r.failed then now() end,
           failed_at = case when r.failed then now() end,
           claimed_at = null,
           settled_deliveries = case when r.next_attempt_at is null then '{}'::jsonb
                                     else r.settled_deliveries end,
           delivery_attempts = r.attempts,
           last_delivery_error = r.last_error,
           next_attempt_at = r.next_attempt_at
      from jsonb_to_recordset(p_results) as r(
        id uuid, claimed_at timestamptz, settled_deliveries jsonb,
        attempts smallint, next_attempt_at timestamptz, failed boolean, last_error text
      )
     where n.id = r.id and n.claimed_at = r.claimed_at
       and n.sent_at is null and n.failed_at is null
    returning n.id
  )
  select count(*)::integer from finished;
$function$;

revoke all on function public.claim_notification_deliveries(integer)
  from public, anon, authenticated;
grant execute on function public.claim_notification_deliveries(integer) to service_role;

revoke all on function public.finish_notification_deliveries(jsonb)
  from public, anon, authenticated;
grant execute on function public.finish_notification_deliveries(jsonb) to service_role;

-- Coalesce only pending room notifications. An exhausted delivery must not
-- prevent new activity in that room from enqueueing a notification.
CREATE OR REPLACE FUNCTION public.enqueue_room_message_notifications()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_author_name text;
begin
  select name into v_author_name from users where id = new.author_id;

  insert into notification_outbox (user_id, kind, payload)
  select m.user_id, 'room_message',
    jsonb_build_object(
      'author_name', v_author_name,
      'room_id', new.room_id,
      'message_id', new.id
    )
  from room_members m
  where m.room_id = new.room_id
    and m.user_id <> new.author_id
    and coalesce(
      (select np.notify_room_messages from notification_preferences np where np.user_id = m.user_id),
      true
    )
    and not m.notifications_muted
    and m.last_read_at < now() - interval '1 minute'
    and not exists (
      select 1 from notification_outbox n
       where n.user_id = m.user_id
         and n.kind = 'room_message'
         and n.sent_at is null
         and n.failed_at is null
         and n.payload ->> 'room_id' = new.room_id::text
    );

  return new;
end;
$function$;
