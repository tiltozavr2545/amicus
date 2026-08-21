-- Ежедневная уборка брошенных регистраций.
--
-- Supabase сам неподтверждённые аккаунты не удаляет: строка в `auth.users`
-- (и, через handle_new_user(), в `public.users`) появляется в момент нажатия
-- «Зарегистрироваться», а не в момент перехода по ссылке из письма. Всё, что
-- не дошло до подтверждения, лежит там вечно. На момент этой миграции так
-- накопилось шесть аккаунтов — половина на `@example.com`, куда письмо не
-- могло дойти в принципе; их удалили руками, а `validateEmail()` на клиенте
-- закрыл этот конкретный вход. Но обычную брошенную регистрацию на живом
-- домене ничто не подметает, поэтому они накопятся снова.
--
-- Условия сознательно узкие — функция удаляет людей, и ошибиться здесь дороже,
-- чем не дочистить:
--   * `email_confirmed_at is null` — подтверждённый аккаунт не трогается
--     никогда, сколько бы он ни простаивал. Неактивность лечится
--     inactive_week-уведомлением, а не удалением.
--   * старше 30 суток — с запасом больше любого разумного «отвлёкся и вернулся
--     на следующий день».
--   * ни одной строки нигде: ни постов, ни комментариев, ни реакций, ни
--     связей, ни инвайтов (своих и активированных), ни фото, ни устройств.
--     Неподтверждённый аккаунт в принципе не может ничего из этого создать —
--     без подтверждения нет сессии, — так что проверка избыточна ровно до тех
--     пор, пока кто-нибудь не поменяет правила подтверждения. Тогда она
--     окажется единственным, что стоит между сменой настройки и удалением
--     живых данных.
--   * `not is_system_account()` — он и так подтверждён, но список условий,
--     защищающий системный аккаунт только по касательной, — это не защита.
--
-- Storage не трогается и не должен: у кандидата по определению нет ни строк
-- `profile_photos`, ни постов, а `storage.objects` требует сессии, которой у
-- неподтверждённого аккаунта не было. Проверено перед удалением тех шести:
-- ноль объектов на всех.
--
-- Выдачи никому нет. Функция вызывается только cron'ом ниже; аргументов у неё
-- нет, но дело не в этом — она удаляет чужие строки, и `authenticated` её
-- видеть не должен вовсе (см. «Каждая функция в public — эндпоинт PostgREST»
-- в CLAUDE.md).

create or replace function public.purge_abandoned_signups()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  with doomed as (
    select au.id
      from auth.users au
     where au.email_confirmed_at is null
       and au.created_at < now() - interval '30 days'
       and not public.is_system_account(au.id)
       and not exists (select 1 from posts p where p.author_id = au.id)
       and not exists (select 1 from comments c where c.author_id = au.id)
       and not exists (select 1 from reactions r where r.user_id = au.id)
       and not exists (select 1 from connections cn
                        where cn.user_a_id = au.id or cn.user_b_id = au.id)
       and not exists (select 1 from invite_links il
                        where il.owner_id = au.id or il.used_by_id = au.id)
       and not exists (select 1 from profile_photos pp where pp.user_id = au.id)
       and not exists (select 1 from device_tokens dt where dt.user_id = au.id)
  ),
  gone as (
    delete from auth.users au
     where au.id in (select id from doomed)
    returning au.id
  )
  select count(*) into v_deleted from gone;

  return v_deleted;
end;
$$;

revoke execute on function public.purge_abandoned_signups() from public, anon, authenticated;

-- 03:40 UTC — вне суточного пика и не в ноль минут, где толпятся все остальные
-- расписания. Ежедневно, потому что работы почти всегда ноль: запрос упирается
-- в `email_confirmed_at is null`, а таких строк в норме единицы.
select cron.schedule(
  'purge-abandoned-signups',
  '40 3 * * *',
  $$ select public.purge_abandoned_signups(); $$
);
