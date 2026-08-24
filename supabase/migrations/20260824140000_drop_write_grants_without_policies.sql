-- Права на запись, под которыми нет ни одной политики.
--
-- Найдено сверкой двух списков: какие команды `authenticated` разрешены
-- грантом и для каких команд на той же таблице вообще существует политика.
-- Расхождение — там, где грант выдан, а политики нет:
--
--   comments        UPDATE (9 колонок)
--   connections     INSERT (5), UPDATE (5)
--   invite_links    INSERT (6), UPDATE (6)
--   post_media      UPDATE (7)
--   profile_photos  UPDATE (5)
--
-- Все пять — дефолтный табличный грант Supabase, переживший то, что его
-- отменяло. У `comments` и `post_media` отсутствие UPDATE-политики объявлено
-- намеренным решением (docs/data-model.md: «редактирование комментариев — не
-- фича»; замена медиа — всегда delete+insert). `profile_photos` то же самое,
-- прямым текстом в 20260819240000. Строки `connections` и `invite_links`
-- заводят только `security definer`-функции (`activate_invite_link()`,
-- `create_invite_link()`, `rotate_invite_link()`), которые исполняются правами
-- владельца и в клиентских грантах не нуждаются.
--
-- СЕГОДНЯ ЭТО НИЧЕГО НЕ ОТКРЫВАЕТ, и снятие ничего не ломает — по одной и той
-- же причине. RLS включена на всех пяти таблицах, `authenticated` не владелец,
-- а команда, для которой нет ни одной политики (и нет политики `for all`),
-- отклоняется всегда. То есть грант недостижим по построению: `revoke` не
-- может отобрать доступ, которым нельзя воспользоваться, а значит не может
-- сломать и установленные сборки из Play. Проверено и с другой стороны —
-- клиент этих таблиц на UPDATE не трогает вовсе: `connections`, `post_media` и
-- `comments` он читает (плюс `on conflict do nothing`-вставка комментария,
-- которой хватает INSERT), `profile_photos` читает и удаляет.
--
-- Снимается ровно потому, что это недостижимо СЕЙЧАС. День, когда на такую
-- таблицу заведут UPDATE-политику — а её заведут ради одной колонки и одного
-- сценария, — грант молча раскроет все остальные колонки: `comments.author_id`
-- и `comments.text` (правка чужого авторства и подмена текста задним числом),
-- `post_media.storage_path` (подмена пути в обход префиксного чека, который
-- живёт только в INSERT-политике), `connections.user_a_id` (переписать, с кем
-- ты знаком), `invite_links.is_used`/`owner_id` (воскресить погашенный код).
-- Тот же приём и тот же довод, что у 20260822210000 (снятие неиспользуемого
-- `update (avatar_path)`) и 20260822240000 (отзыв TRUNCATE): забытая
-- привилегия должна быть закрытой, а не открытой.
--
-- Таблицы с политикой `for all` (`muted_users`, `blocked_users`,
-- `favorite_users`, `device_tokens`, `notification_preferences`) НЕ трогаются:
-- у них UPDATE достижим и нужен — тамошние `upsert` клиента приезжают как
-- `on conflict do update`. `reactions` тоже не трогается: у неё своя
-- UPDATE-политика «Users can change their own reaction».
--
-- INSERT-гранты `comments`, `post_media`, `profile_photos` НЕ трогаются: они
-- поимённые (20260818130000 и далее), под ними есть политики, и по ним ходят
-- установленные сборки.

revoke update on public.comments from authenticated;
revoke update on public.post_media from authenticated;
revoke update on public.profile_photos from authenticated;
revoke insert, update on public.connections from authenticated;
revoke insert, update on public.invite_links from authenticated;

-- Контрольная проверка: после наката ни одной пары «грант без политики» для
-- `authenticated` остаться не должно. Падение здесь означает, что список выше
-- неполон, а не что накат не удался.
do $$
declare
  v_left text;
begin
  select string_agg(t.table_name || '.' || t.privilege_type, ', ')
    into v_left
    from (
      select cp.table_name, cp.privilege_type
        from information_schema.column_privileges cp
       where cp.table_schema = 'public'
         and cp.grantee = 'authenticated'
         and cp.privilege_type in ('INSERT', 'UPDATE', 'DELETE')
       group by cp.table_name, cp.privilege_type
    ) t
   where not exists (
     select 1
       from pg_policy p
       join pg_class c on c.oid = p.polrelid
       join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public'
        and c.relname = t.table_name
        and (
          p.polcmd = '*'
          or p.polcmd = case t.privilege_type
                          when 'INSERT' then 'a'
                          when 'UPDATE' then 'w'
                          when 'DELETE' then 'd'
                        end
        )
   );

  if v_left is not null then
    raise exception 'write grants still without a policy: %', v_left;
  end if;
end
$$;
