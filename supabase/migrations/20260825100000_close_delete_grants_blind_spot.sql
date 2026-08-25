-- Тот же аудит, что и в 20260824140000, но теперь он видит DELETE.
--
-- Проверка из 20260824140000 сверяет гранты с политиками по
-- `information_schema.column_privileges`. Это правильный источник для INSERT и
-- UPDATE — их можно выдать поколоночно, и табличного гранта при этом может не
-- быть вовсе, — но DELETE поколоночным не бывает: в стандарте это привилегия
-- уровня таблицы, и в `column_privileges` она не появляется НИКОГДА. Вся
-- команда прошла мимо проверки, которая была написана ровно для того, чтобы
-- такого не оставалось.
--
-- Что за ней пряталось:
--
--   comments      DELETE
--   connections   DELETE
--   invite_links  DELETE
--   users         DELETE
--
-- Все четыре — дефолтный табличный грант Supabase. Ни под одним нет политики,
-- то есть СЕГОДНЯ ОНИ НЕ ОТКРЫВАЮТ НИЧЕГО: команда, под которой нет ни одной
-- политики, отклоняется всегда. Снимаются они не ради сегодняшнего дня, а
-- ради того, чтобы завтрашняя политика не включила их молча.
--
-- У `comments` цена такой политики особенно велика, и это стоит записать
-- рядом с грантом, а не только в docs/data-model.md. `parent_comment_id`
-- объявлен `on delete cascade` (20260725120000), поэтому прямой DELETE
-- корневого комментария унёс бы с собой ответы ДРУГИХ людей. Именно поэтому
-- 20260725120000 сняла DELETE-политику, которую завела 20260710113710, и
-- оставила единственным путём `delete_own_comment()`: тот решает
-- «заглушка или настоящее удаление» на сервере и атомарно. Грант, переживший
-- снятие политики, — это заряженная половина той же дыры, ждущая второй.
--
-- `connections` и `invite_links` строки заводят и удаляют только
-- `security definer`-функции (`activate_invite_link()`, `rotate_invite_link()`),
-- исполняющиеся правами владельца, — в клиентских грантах они не нуждаются, и
-- 20260824140000 уже сняла с них INSERT и UPDATE по этой же причине. `users`
-- удаляется каскадом от `auth.users`, куда ведёт `delete_own_account()`.

revoke delete on public.comments from authenticated;
revoke delete on public.connections from authenticated;
revoke delete on public.invite_links from authenticated;
revoke delete on public.users from authenticated;

-- Тот же контрольный блок, что и в 20260824140000, но по обоим источникам:
-- поколоночные INSERT/UPDATE — из `column_privileges`, табличный DELETE — из
-- `role_table_grants`. Падает, если после этой миграции остался хоть один
-- грант на запись, под которым нет политики.
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
         and cp.privilege_type in ('INSERT', 'UPDATE')
       group by cp.table_name, cp.privilege_type
      union
      select tg.table_name, tg.privilege_type
        from information_schema.role_table_grants tg
       where tg.table_schema = 'public'
         and tg.grantee = 'authenticated'
         and tg.privilege_type = 'DELETE'
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
