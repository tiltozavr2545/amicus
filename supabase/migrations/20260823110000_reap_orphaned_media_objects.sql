-- Объекты в бакете, на которые не ссылается ни одна строка, перестают жить
-- вечно.
--
-- Лимиты «20 медиа на пост» и «80 фото в профиле» — строчные: их считают
-- триггеры enforce_post_media_limit()/enforce_profile_photos_limit() по
-- таблицам. В сам бакет они не смотрят и смотреть не могут, а storage-политика
-- на INSERT (20260708172235, 20260707222025) проверяет ровно один факт —
-- совпадает ли второй сегмент пути с auth.uid(). Поэтому объект без строки не
-- нарушает вообще ничего и не удаляется никем.
--
-- Это не гипотеза, это норма работы приложения. createPost заливает ВСЕ файлы
-- до вставки строки поста (иначе пост на секунду появился бы без фотографий),
-- так что каждый брошенный черновик оставляет за собой ровно то, что успел
-- залить. Плюс два исторических источника: посты и аватарки удалённых
-- пользователей (delete_own_account() каскадит только по БД — из бакета
-- удаляет клиент, и это best-effort по построению, см. deleteRowsThenObjects)
-- и пути дореформенного формата `posts/<uid>/<имя>.png`, чьи строки не пережили
-- переезд в post_media (20260819220000). На момент этой миграции в бакете
-- 31 объект, из них 5 не нужны никому — 888 KB на 28 MB.
--
-- Почему через HTTP, а не `delete from storage.objects`. Строка в
-- storage.objects — это индекс метаданных, а байты лежат в S3 и принадлежат
-- storage-api. Удалить строку напрямую значит рассинхронизировать их: объект
-- исчезнет из листингов и политик, но останется в S3 навсегда и продолжит
-- тарифицироваться — то есть ровно та проблема, которую эта миграция и
-- закрывает, только теперь невидимая. Удаляет storage-api, он же убирает
-- строку.
--
-- Отсюда же свойство, ради которого функция НЕ трогает storage.objects сама:
-- pg_net отправляет запрос и забывает про него, ответ приезжает в
-- net._http_response, и никто его не читает. Если вызов не прошёл (протух
-- ключ, недоступен storage-api), строки остаются на месте и следующий запуск
-- попробует снова. Джоб, который «удалил» строки, но не байты, чинить пришлось
-- бы руками; этот самовосстанавливается. Ср. заметку про молчаливую потерю
-- пушей в send-push/index.ts.
--
-- Три ограничителя, все три — про то, чтобы ошибка в предикате не стоила
-- пользователям фотографий:
--   * 24 часа с момента заливки. Легально несвязанным объект бывает только
--     между своей заливкой и вставкой строки — это один round trip, а самый
--     щедрый клиентский дедлайн (uploadTimeout на 100 MiB) равен 15 минутам.
--     Сутки — это с запасом в сто раз. Тот же приём и та же логика, что у
--     purge_empty_posts() с его часом (20260822200000).
--   * распознанная форма пути. Второй сегмент обязан быть uuid'ом, первый —
--     `posts` или `avatars`. Всё остальное функция не понимает и потому не
--     трогает: под это правило не попадают, например, `posts/`
--     и `avatars/.emptyFolderPlaceholder` — служебные строки, которыми
--     дашборд рисует папки.
--   * 100 объектов за запуск. Не оптимизация, а предохранитель: цена ошибки в
--     предикате выше при удалении всего бакета разом, чем при удалении сотни.
--     Остаток уедет следующей ночью.
--
-- Секрет для авторизации — существующий `send_push_service_role_key`. Имя
-- историческое и теперь неточное (его читают два джоба, а не один), но
-- заводить вторую запись Vault с тем же значением значит завести вторую копию
-- одного секрета, а это ровно то, от чего предостерегает CLAUDE.md. Одна
-- копия важнее аккуратного имени. `storage_object_url` заведён отдельно —
-- это адрес, а не секрет, и лежит он в Vault по той же причине, по которой
-- там лежит `send_push_function_url`: кроновой команде больше неоткуда его
-- взять.

-- Отдельно от reap_orphaned_media() намеренно: этот запрос надо иметь
-- возможность посмотреть глазами, не удаляя ничего, — и до первого запуска, и
-- когда захочется понять, что джоб собирается снести.
create or replace function public.orphaned_media_paths()
returns setof text
language sql
stable
security definer
set search_path = public
as $$
  select o.name
    from storage.objects o
   where o.bucket_id = 'media'
     and o.created_at < now() - interval '24 hours'
     and (storage.foldername(o.name))[1] in ('posts', 'avatars')
     and (storage.foldername(o.name))[2] ~
         '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and not exists (
       select 1 from post_media m
        where m.storage_path = o.name or m.poster_path = o.name
     )
     and not exists (
       select 1 from profile_photos p where p.storage_path = o.name
     )
     -- Избыточно, пока sync_avatar_path_from_profile_photos() держит колонку в
     -- синхроне с profile_photos, — но именно на эту колонку смотрит весь
     -- остальной клиент, и она переживала уже одну миграцию формата
     -- (20260820100000). Проверить её стоит один exists.
     and not exists (
       select 1 from users u where u.avatar_path = o.name
     )
   order by o.name
   limit 100;
$$;

revoke execute on function public.orphaned_media_paths() from public, anon, authenticated;

create or replace function public.reap_orphaned_media()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_paths text[];
begin
  select array_agg(p) into v_paths from public.orphaned_media_paths() p;

  if v_paths is null then
    return 0;
  end if;

  -- Batch-эндпоинт: один запрос на запуск, а не один на объект.
  perform net.http_delete(
    url := (select decrypted_secret from vault.decrypted_secrets
             where name = 'storage_object_url'),
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                      where name = 'send_push_service_role_key'),
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('prefixes', to_jsonb(v_paths))
  );

  -- Строки storage.objects тут не трогаются намеренно — см. заголовок.
  return array_length(v_paths, 1);
end;
$$;

revoke execute on function public.reap_orphaned_media() from public, anon, authenticated;

-- 04:45 — свободная минута: 03:40 занят purge-abandoned-signups, 05:10
-- purge-notification-outbox, 12:00 inactive-week-nudge, :20 каждого часа
-- purge-empty-posts.
select cron.schedule(
  'reap-orphaned-media',
  '45 4 * * *',
  $$ select public.reap_orphaned_media(); $$
);
