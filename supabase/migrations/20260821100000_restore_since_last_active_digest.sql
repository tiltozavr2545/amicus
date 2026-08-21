-- Восстановление дайджеста «с момента последнего входа», молча откаченного
-- двумя последними миграциями.
--
-- Что произошло. 20260819190000 заменила счётчик pending_post_counts окном по
-- user_activity.last_active_at и **дропнула саму таблицу** (:48). Следующие
-- две миграции — 20260820170000 и 20260820190000 — правили в
-- enqueue_post_notifications() только ветку системного аккаунта, но написаны
-- были поверх *дореформенного* текста функции и накатили его целиком через
-- `create or replace`. Вместе с ненужной им веткой вернулся и цикл дайджеста,
-- пишущий в pending_post_counts, которой больше нет.
--
-- Почему это не поймали ни тесты, ни накат: `check_function_bodies` проверяет
-- тело plpgsql только синтаксически, имена таблиц разрешаются в рантайме, при
-- первом же выполнении оператора. Обе миграции применились без единой жалобы.
--
-- Чем это было в проде. Триггер on_post_created_enqueue_notifications —
-- AFTER INSERT в транзакции самой вставки, поэтому `relation
-- "pending_post_counts" does not exist` откатывал сам пост. Публикация
-- ломалась не у всех, а ровно у тех, у кого есть хоть одна Connection, не
-- попавшая ни в mute, ни в block, ни в избранное: только у такого зрителя
-- цикл доходит до тела и до несуществующей таблицы. На момент этой миграции —
-- 7 из 15 живых аккаунтов.
--
-- Здесь тело собирается заново из двух источников явно: ранний выход для
-- системного аккаунта — из 20260820190000 (посты системного аккаунта больше
-- не порождают уведомлений сами по себе), блок избранного и цикл дайджеста —
-- из 20260819190000. Ничего нового не вводится, только восстанавливается то,
-- что должно было остаться.
--
-- На будущее: правка одной ветки в теле функции всё равно переписывает всё
-- тело. Брать исходник надо из миграции, которая правила эту функцию
-- последней, а не из той, что помнится.

create or replace function public.enqueue_post_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author_name text;
  v_viewer_id uuid;
  v_window_start timestamptz;
  v_unseen_count int;
begin
  -- 20260820190000: пост системного аккаунта сам по себе не уведомляет
  -- никого. Kind 'app_update' и notify_system_account остаются для того, кто
  -- будет слать это уведомление отдельно.
  if public.is_system_account(new.author_id) then
    return new;
  end if;

  select name into v_author_name from users where id = new.author_id;

  insert into notification_outbox (user_id, kind, payload)
  select f.user_id, 'new_post',
    jsonb_build_object(
      'author_id', new.author_id,
      'author_name', v_author_name,
      'post_id', new.id
    )
  from favorite_users f
  where f.favorite_id = new.author_id
    and public.are_connected(f.user_id, new.author_id)
    and not public.has_muted(f.user_id, new.author_id)
    and not public.is_blocked_pair(f.user_id, new.author_id)
    and coalesce(
      (select notify_favorites from notification_preferences where user_id = f.user_id),
      true
    );

  for v_viewer_id in
    select case when c.user_a_id = new.author_id then c.user_b_id else c.user_a_id end as viewer_id
      from connections c
     where c.user_a_id = new.author_id or c.user_b_id = new.author_id
     order by viewer_id
  loop
    continue when public.has_muted(v_viewer_id, new.author_id);
    continue when public.is_blocked_pair(v_viewer_id, new.author_id);
    continue when exists (
      select 1 from favorite_users f
      where f.user_id = v_viewer_id and f.favorite_id = new.author_id
    );
    continue when not coalesce(
      (select notify_digest from notification_preferences where user_id = v_viewer_id),
      true
    );

    -- Never having opened the (updated) app yet reads as "just became
    -- active" — nothing counts as unseen until we actually know otherwise.
    select coalesce(
      (select last_active_at from user_activity where user_id = v_viewer_id),
      now()
    ) into v_window_start;

    -- Already sent a digest since they were last active — the count can only
    -- have grown since, so nothing new to decide until they open the app
    -- again and this window moves forward.
    continue when exists (
      select 1 from notification_outbox n
      where n.user_id = v_viewer_id
        and n.kind = 'digest'
        and n.created_at > v_window_start
    );

    -- Direct joins against the base tables rather than has_muted()/
    -- is_blocked_pair() per row — those are fine called once per viewer
    -- (above), but calling a SECURITY DEFINER function per candidate post
    -- here is exactly the row-filter cost CLAUDE.md's "Грабли" warns about.
    select count(*) into v_unseen_count
    from posts p
    join connections c
      on (c.user_a_id = v_viewer_id and c.user_b_id = p.author_id)
      or (c.user_b_id = v_viewer_id and c.user_a_id = p.author_id)
    where p.created_at > v_window_start
      and not exists (
        select 1 from muted_users m
        where m.muter_id = v_viewer_id and m.muted_id = p.author_id
      )
      and not exists (
        select 1 from blocked_users b
        where (b.blocker_id = v_viewer_id and b.blocked_id = p.author_id)
           or (b.blocker_id = p.author_id and b.blocked_id = v_viewer_id)
      )
      and not exists (
        select 1 from favorite_users f
        where f.user_id = v_viewer_id and f.favorite_id = p.author_id
      );

    if v_unseen_count >= 7 then
      insert into notification_outbox (user_id, kind, payload)
      values (v_viewer_id, 'digest', jsonb_build_object('count', v_unseen_count));
    end if;
  end loop;

  return new;
end;
$$;
