-- =====================================================================
-- `auth.uid()` в RLS-политиках — через `(select auth.uid())`.
--
-- Что нашёл Performance Advisor (lint 0003_auth_rls_initplan): в 27
-- политиках `auth.uid()` стоит голым вызовом. Планировщик тогда считает его
-- заново для КАЖДОЙ проверяемой строки, хотя на протяжении запроса значение
-- не меняется. Обёрнутый в скалярный подзапрос `(select auth.uid())`, он
-- превращается в InitPlan и вычисляется один раз на запрос.
--
-- Семантика не меняется: `auth.uid()` — STABLE и читает `request.jwt.claims`,
-- которые внутри запроса постоянны. Меняется только число вычислений. Эффект
-- растёт с размером просматриваемой таблицы, то есть заметнее всего на
-- `posts`, `reactions`, `comments` и `users`, где RLS решает видимость до
-- `LIMIT`.
--
-- Как переписывается. Тела политик не копируются руками: их 27, и опечатка в
-- одной из них молча сменила бы условие доступа. Вместо этого цикл берёт
-- ЖИВОЕ определение из `pg_policies` (источник истины — схема, а не
-- миграции, см. «Конвенции работы» в AGENTS.md), заменяет каждый голый
-- `auth.uid()` на `(select auth.uid())` и применяет `alter policy`. Роли,
-- команда и PERMISSIVE/RESTRICTIVE у `alter policy` не затрагиваются; если у
-- политики только USING или только WITH CHECK, второе не появляется.
--
-- Идемпотентность. Regexp пропускает вызов, перед которым уже стоит
-- `select `: после первого прогона `pg_policies` показывает
-- `( SELECT auth.uid() AS uid)`, и повторный накат ничего не трогает.
--
-- Самопроверка внутри миграции (падение откатывает всё):
--   1. число политик в `public` не изменилось;
--   2. голых `auth.uid()` не осталось ни в одной политике схемы `public`;
--   3. если вернуть `(select auth.uid())` обратно в голый вызов, каждое
--      выражение совпадает с тем, что было до правки, — то есть кроме обёртки
--      не изменилось ни одного символа условия.
--
-- Что НЕ трогается: политики `storage.objects` (Advisor их не называет, и
-- чужую схему мы не правим), `current_setting()` (в наших политиках его нет)
-- и `security definer`-функции — внутри функции `auth.uid()` вызывается один
-- раз за вызов, это другая история.
--
-- На будущее: в новых политиках сразу писать `(select auth.uid())`.
-- =====================================================================

create temp table _policies_before on commit drop as
  select schemaname, tablename, policyname, qual, with_check
    from pg_policies
   where schemaname = 'public';

do $$
declare
  p record;
  v_stmt text;
  v_touched int := 0;
  -- Голый вызов: не после `select ` (регистр не важен — pg_policies
  -- показывает `SELECT`).
  c_bare constant text := '(?<!select )auth\.uid\(\)';
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check
      from pg_policies
     where schemaname = 'public'
       and (qual ~* c_bare or with_check ~* c_bare)
     order by tablename, policyname
  loop
    v_stmt := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);

    if p.qual is not null then
      v_stmt := v_stmt || format(
        ' using (%s)', regexp_replace(p.qual, c_bare, '(select auth.uid())', 'gi'));
    end if;
    if p.with_check is not null then
      v_stmt := v_stmt || format(
        ' with check (%s)', regexp_replace(p.with_check, c_bare, '(select auth.uid())', 'gi'));
    end if;

    execute v_stmt;
    v_touched := v_touched + 1;
  end loop;

  raise notice 'auth.uid() обёрнут в select в % политиках', v_touched;
end;
$$;

-- ---------------------------------------------------------------------
-- Самопроверка
-- ---------------------------------------------------------------------
do $$
declare
  v_before int;
  v_after int;
  v_bare text;
  v_diff text;
begin
  select count(*) into v_before from _policies_before;
  select count(*) into v_after from pg_policies where schemaname = 'public';
  if v_before <> v_after then
    raise exception 'число политик изменилось: было %, стало %', v_before, v_after;
  end if;

  select string_agg(tablename || '.' || policyname, ', ') into v_bare
    from pg_policies
   where schemaname = 'public'
     and (qual ~* '(?<!select )auth\.uid\(\)' or with_check ~* '(?<!select )auth\.uid\(\)');
  if v_bare is not null then
    raise exception 'голый auth.uid() остался в: %', v_bare;
  end if;

  -- Развёрнутая обратно обёртка обязана дать ровно прежнее выражение.
  -- `( SELECT auth.uid() AS uid)` — так её печатает pg_get_expr.
  --
  -- Разворачиваются ОБЕ стороны, а не только «после»: политика, обёрнутая
  -- ещё до наката (повторный прогон, ручная правка живой схемы), цикл не
  -- трогает, и её «до» уже содержит обёртку. Сравнение развёрнутого «после»
  -- с сырым «до» валило миграцию на каждой такой политике — то есть ровно
  -- на повторном накате, который шапка обещает безвредным.
  select string_agg(a.tablename || '.' || a.policyname, ', ') into v_diff
    from pg_policies a
    join _policies_before b using (schemaname, tablename, policyname)
   where a.schemaname = 'public'
     and (
       regexp_replace(coalesce(a.qual, ''),
                      '\( SELECT auth\.uid\(\) AS uid\)', 'auth.uid()', 'g')
         is distinct from
       regexp_replace(coalesce(b.qual, ''),
                      '\( SELECT auth\.uid\(\) AS uid\)', 'auth.uid()', 'g')
       or regexp_replace(coalesce(a.with_check, ''),
                         '\( SELECT auth\.uid\(\) AS uid\)', 'auth.uid()', 'g')
         is distinct from
          regexp_replace(coalesce(b.with_check, ''),
                         '\( SELECT auth\.uid\(\) AS uid\)', 'auth.uid()', 'g')
     );
  if v_diff is not null then
    raise exception 'условие изменилось не только обёрткой: %', v_diff;
  end if;
end;
$$;
