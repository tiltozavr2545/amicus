# Эксплуатация

Что крутится само, где лежат секреты и что делать руками. Отдельно от
[data-model.md](data-model.md), потому что это не схема: схема отвечает на
вопрос «как устроено», этот файл — «что нажать».

**Почему** конкретное решение принято так — по-прежнему в комментарии
соответствующей миграции, а не здесь.

---

## Задания по расписанию (pg_cron)

Все шесть живут в базе, заводятся миграциями и видны через
`select jobname, schedule, active from cron.job`.

| Задание | Когда | Что делает | Миграция |
|---|---|---|---|
| `drain-notification-outbox` | каждую минуту | дёргает Edge Function `send-push`, та разгребает `notification_outbox` | 20260818200000, заголовок добавлен в 20260820160000 |
| `inactive-week-nudge` | ежедневно 12:00 UTC | ставит в очередь «неделю без постов» | 20260818190000 |
| `purge-abandoned-signups` | ежедневно 03:40 UTC | сносит неподтверждённые регистрации старше 30 суток с нулевой активностью | 20260822100000 |
| `purge-empty-posts` | ежечасно в :20 | сносит посты без текста и без единой строки `post_media` старше часа | 20260822200000 |
| `reap-orphaned-media` | ежедневно 04:45 UTC | сносит из бакета объекты, на которые не ссылается ни одна строка, старше суток — не больше 100 за запуск | 20260823110000 |
| `purge-notification-outbox` | ежедневно 05:10 UTC | сносит строки `notification_outbox` старше 90 суток | 20260823100000 |

Расписания намеренно разнесены по минутам, а не поставлены все в :00.

Посмотреть, что `reap-orphaned-media` собирается снести, не удаляя ничего:

```sql
select * from public.orphaned_media_paths();
```

Она же — единственный безопасный способ проверить предикат после правки: сам
джоб удаляет байты через storage-api и обратно их не вернуть. Строки
`storage.objects` руками не удалять никогда — это индекс метаданных, а файлы
живут в S3 и без storage-api останутся там навсегда, уже невидимые.

## Секреты

Ни один из перечисленных не лежит в репозитории. Три разных хранилища, и
путать их дорого — см. грабли про `SUPABASE_SERVICE_ROLE_KEY` в
[../CLAUDE.md](../CLAUDE.md).

**Vault базы** (`select name from vault.secrets`) — их читает cron-задание
`drain-notification-outbox`:

| Имя | Что это |
|---|---|
| `send_push_function_url` | URL Edge Function |
| `send_push_service_role_key` | bearer для платформенного гейта `verify_jwt`. Имя историческое: это service-role ключ проекта, и с 20260823110000 его читает ещё и `reap-orphaned-media`. Заводить под второе имя вторую копию того же значения намеренно не стали — одна копия секрета важнее точного имени |
| `send_push_shared_secret` | доказательство «звонит именно cron», едет в своём заголовке `x-send-push-secret` |
| `storage_object_url` | batch-эндпоинт удаления в бакете `media`, читает `reap-orphaned-media`. Не секрет, а адрес — лежит здесь по той же причине, что и `send_push_function_url`: кроновой команде больше неоткуда его взять |

Заводятся один раз, снаружи миграций:

```sql
select vault.create_secret('<значение>', 'send_push_shared_secret');
```

**Секреты Edge Function** (`supabase secrets set …`): `FCM_PROJECT_ID`,
`FCM_SERVICE_ACCOUNT_JSON`, `SEND_PUSH_SECRET` — последний обязан совпадать с
`send_push_shared_secret` из Vault и быть не короче 32 символов, иначе функция
осознанно отказывается стартовать. `SUPABASE_URL` и
`SUPABASE_SERVICE_ROLE_KEY` инжектит сама платформа, задавать их не надо.

**Секреты GitHub** (нужны `deploy-closed-testing.yml`, workflow проверяет
наличие всех восьми до сборки): `ANDROID_KEYSTORE_BASE64`,
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`,
`PLAY_SERVICE_ACCOUNT_JSON`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`GOOGLE_SERVICES_JSON`.

**Локально**: `app/.env` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`), шаблон —
`app/.env.example`. Плюс `app/android/key.properties` и
`app/android/app/google-services.json` — оба в `.gitignore`, источник правды у
них Play Console и Firebase, а не git.

## Релиз

Пуш в `main` запускает `deploy-closed-testing.yml`: он сам прогоняет
`make verify` и проверку бампа версии (не полагаясь на то, что CI был зелёным),
собирает подписанный `.aab` и выкладывает его в **Google Play → Closed testing,
трек `alpha`**, после чего комментирует в PR напоминание. Ручных шагов в самой
выкладке нет.

Что остаётся руками после выкладки:

1. Пост от новостного аккаунта Amicus, если релиз того стоит (об этом и
   напоминает комментарий в PR). Сам по себе такой пост уведомлений **не
   рассылает** — эту связь сняли в 20260820190000.
2. Рассылка «обновитесь», если она нужна:

   ```sql
   select public.enqueue_app_update_notifications(41, '0.16.7');
   ```

   Первый аргумент — `versionCode` (`+41` из `pubspec.yaml`), второй — только
   для чтения глазами. Отставшим считается тот, у кого максимум `app_build` по
   всем его устройствам ниже целевого. Повторный вызов с той же сборкой
   безопасен: дедупликация идёт по `payload->>'build'`, одно уведомление на
   релиз. Функция никому не выдана — только через Management API.

Посмотреть, кто на какой версии сидит:

```sql
select coalesce(app_version, 'unknown') as version, count(*)
  from device_tokens group by 1 order by 1;
```

## Миграции

Накатываются вручную через Supabase Management API, CI этого не делает.
Порядок, требование дописать строку в `supabase_migrations.schema_migrations` и
правило «RLS проверять симуляцией, а не на глаз» — в разделе «Конвенции работы»
[../CLAUDE.md](../CLAUDE.md); здесь они не повторяются, чтобы не разъехались.

Сверка, что репозиторий и база не разошлись, — количество файлов против
количества строк:

```bash
ls supabase/migrations/*.sql | wc -l
```
```sql
select count(*) from supabase_migrations.schema_migrations;
```
