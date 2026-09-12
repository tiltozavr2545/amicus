-- =====================================================================
-- Чем закончилась попытка зарегистрировать пуш-токен.
--
-- Вопрос, на который до сих пор нельзя было ответить: почему у человека,
-- который вчера открывал приложение, нет ни одной строки в `device_tokens`.
-- Регистрация у него точно шла — `pushRegistrationProvider` смотрится в
-- `MainShellScreen` соседней строкой с `userActivityProvider`, так что
-- наличие строки в `user_activity` доказывает, что шелл отрисовался, — но
-- `registerDevice()` имеет ТРИ выхода без строки, и все три молчаливые:
--
--   1. отказ в разрешении на уведомления (`AuthorizationStatus.denied`);
--   2. `getToken()` вернул null (нет Play Services, сбой Firebase);
--   3. апсерт бросил исключение — оно уходит в `FutureProvider`, чьё
--      состояние никто не читает, и исчезает совсем.
--
-- Снаружи все три выглядят одинаково: человека просто нет в device_tokens.
-- Пока их не различить, каждый следующий такой вопрос будет упираться в
-- «неизвестно», а третий случай — наш собственный сбой — неотличим от
-- законного отказа пользователя.
--
-- Строка одна на человека, а не на устройство, и это осознанное сужение:
-- при неудаче у нас нет идентификатора установки (токен — он и есть
-- идентификатор, а его-то и не получили), так что ключом может быть только
-- пользователь. Цена — у человека с двумя телефонами видно состояние
-- последнего открывшегося. Для вопроса «почему до него не доходит» этого
-- достаточно, а для «какие у него устройства» есть device_tokens.
--
-- `app_version`/`app_build`/`platform`/`os_version` дублируют колонки
-- `device_tokens` намеренно: там они появляются ТОЛЬКО при успешной
-- регистрации, то есть ровно у тех, про кого и так всё понятно. Здесь это
-- единственный способ узнать версию и платформу того, у кого токена нет.
-- Ограничения повторены дословно — иначе форматы разъедутся, и сводка по
-- версиям начнёт считать `18.1` и `Version 18.1` разными вещами.
-- =====================================================================

create table public.push_registration_status (
  user_id uuid not null,
  status text not null,
  platform text,
  os_version text,
  app_version text,
  app_build integer,
  -- Код или обрывок сообщения ошибки — только для `error`. Не для показа
  -- человеку, а чтобы в консоли было видно, что именно ломается.
  detail text,
  updated_at timestamp with time zone default now() not null,
  constraint push_registration_status_pkey primary key (user_id),
  constraint push_registration_status_status_check
    check (status = any (array['granted'::text, 'denied'::text,
                               'no_token'::text, 'error'::text])),
  constraint push_registration_status_platform_check
    check (platform is null or platform = any (array[
      'android'::text, 'ios'::text, 'macos'::text,
      'windows'::text, 'linux'::text, 'fuchsia'::text, 'web'::text
    ])),
  constraint push_registration_status_os_version_format
    check (os_version is null or os_version ~ '^[0-9]+(\.[0-9]+){0,2}$'),
  constraint push_registration_status_app_version_format
    check (app_version is null or app_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  constraint push_registration_status_app_build_positive
    check (app_build is null or app_build > 0),
  constraint push_registration_status_detail_length
    check (detail is null or char_length(detail) <= 300),
  constraint push_registration_status_user_id_fkey
    foreign key (user_id) references public.users(id) on delete cascade
);

create index push_registration_status_status_idx
  on public.push_registration_status using btree (status)
  where status <> 'granted';

alter table public.push_registration_status enable row level security;

-- Время ставит сервер, как и у `device_tokens` (pin_device_token_timestamps):
-- поле отвечает на вопрос «когда мы это видели», и ответ на него не должен
-- зависеть от часов телефона.
create or replace function public.pin_push_registration_timestamp()
 returns trigger
 language plpgsql
as $function$
begin
  new.updated_at := now();
  return new;
end;
$function$;

create trigger pin_push_registration_timestamp
  before insert or update on public.push_registration_status
  for each row execute function public.pin_push_registration_timestamp();

create policy "Users manage their own push registration status"
  on public.push_registration_status
  for all
  to authenticated
  using ((user_id = auth.uid()))
  with check ((user_id = auth.uid()));

-- Дефолтные привилегии схемы выдают `authenticated` на новую таблицу всё
-- сразу; сначала снять, потом выдать поколоночно (см. «Новая таблица и новая
-- функция в public приезжают с полными правами» в AGENTS.md).
--
-- UPDATE нужен, потому что запись идёт апсертом по первичному ключу, а он
-- всегда разворачивается в DO UPDATE. SELECT — тоже, и на ТАБЛИЦУ, а не на
-- колонку: `ON CONFLICT DO UPDATE` читает строку, с которой столкнулся,
-- чтобы применить к ней `using`-выражение политики, и поколоночного гранта
-- на колонку из этого выражения ему не хватает. Проверено зондом: плоский
-- `insert` проходит с одной лишь колонкой `user_id`, а апсерт отбивается по
-- 42501 «permission denied for table» — то есть право проверяется шире
-- выражения. Не дыра: RLS всё равно сужает выдачу до собственной строки, а
-- свой же статус уведомлений человеку видеть не вредно. Дополняет граблю
-- «upsert из PostgREST требует НЕчастичного индекса и UPDATE-гранта» в
-- AGENTS.md: SELECT там тоже нужен.
revoke all on table public.push_registration_status from anon, authenticated;
grant select on table public.push_registration_status to authenticated;
grant insert (user_id, status, platform, os_version, app_version, app_build, detail)
  on table public.push_registration_status to authenticated;
grant update (status, platform, os_version, app_version, app_build, detail)
  on table public.push_registration_status to authenticated;

revoke execute on function public.pin_push_registration_timestamp() from anon, authenticated;
