-- IMM-542: у `authenticated` были `rwU` на `room_members_seq_seq` —
-- последовательность identity-колонки `room_members.seq`, по наименьшему
-- значению которой `room_owner_id()` решает, кто владелец комнаты. `w` — это
-- в том числе `setval`, то есть право перемотать счётчик.
--
-- Дырой это не было: `nextval`/`setval` живут в `pg_catalog`, который
-- PostgREST не публикует, а INSERT в `room_members` у роли нет вовсе —
-- комнаты пишут только `security definer`-RPC, и последовательность они
-- двигают правами владельца. Но грант не служит ничему, а пришёл он из
-- дефолтных привилегий схемы, которые baseline снял только у `anon`
-- (20261018000000, раздел 9). Значит следующая serial/identity-колонка
-- получила бы то же самое — снимается и дефолт.
--
-- Дефолт снимается у `postgres`: он владелец всего нашего, и именно его
-- `pg_default_acl` выдаёт `authenticated=rwU`. Запись у `supabase_admin`
-- остаётся — это объекты платформы, и `postgres` её не правит.

revoke all on sequence public.room_members_seq_seq from public, authenticated;

alter default privileges in schema public revoke all on sequences from authenticated;

-- Проверки. Через `has_sequence_privilege`, а не чтением `relacl`: грант
-- PUBLIC в ACL выглядит безымянным `=…/postgres`, и глаз его пропускает
-- (так уже было с функциями, 20260924100000).
do $check$
declare
  v_bad text;
begin
  select string_agg(format('%s:%s', c.relname, r.rolname), ', ') into v_bad
    from pg_class c
    cross join (values ('anon'), ('authenticated')) r(rolname)
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'S'
     and (has_sequence_privilege(r.rolname, c.oid, 'usage')
          or has_sequence_privilege(r.rolname, c.oid, 'select')
          or has_sequence_privilege(r.rolname, c.oid, 'update'));
  if v_bad is not null then
    raise exception 'последовательности открыты клиенту: %', v_bad;
  end if;

  if exists (
    select 1 from pg_default_acl d
     where d.defaclnamespace = 'public'::regnamespace
       and d.defaclrole = 'postgres'::regrole
       and d.defaclobjtype = 'S'
       and d.defaclacl::text ~ '[{,](anon|authenticated)?='
  ) then
    raise exception 'дефолтные права на последовательности всё ещё выдаются клиенту';
  end if;
end
$check$;
