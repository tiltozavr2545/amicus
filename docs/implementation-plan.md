# Implementation Plan: Amicus (ранее «Круг») (MVP)

Пошаговый план реализации MVP из [project-brief.md](project-brief.md), с CI и деплоем, встроенными в этапы, а не отложенными на конец. Проект mobile-first (Android; iOS через Flutter отложен — см. [future-development.md](future-development.md)), web не рассматривается.

## Прогресс

- [x] Этап 0 — Подготовка + скелет CI
- [x] Этап 1 — Auth + профиль
- [x] Этап 2 — Connections (знакомства)
- [x] Этап 3 — Общая лента
- [x] Этап 4 — Реакции и комментарии
- [x] Этап 5 — Полировка + деплой (Android; iOS отложен)

**MVP (0.1) полностью реализован и задеплоен.** Дальнейшая работа — по [future-development.md](future-development.md).

---

## Этап 0 — Подготовка + скелет CI

**Статус:** сделано

1. ✅ Flutter SDK установлен — **версия закреплена на 3.32.8**: последняя (3.44.x) требует macOS 14+, а на этой машине macOS 12.7.6 (Monterey). Более новые версии ставить нельзя, пока не обновится macOS. SDK лежит в `~/development/flutter`, добавлен в PATH через `~/.zshrc`.
   - ✅ Android toolchain: Android Studio + cmdline-tools установлены, лицензии приняты, `flutter doctor` зелёный по Android.
   - ⏸️ Xcode: не устанавливается — решено делать сначала только Android, iOS отложен до обновления macOS (см. future-development.md).
2. ✅ `flutter create --platforms=android,ios` в `app/` (org `com.github.tiltozavr2545`), подключены `supabase_flutter`, `go_router`, `flutter_riverpod`, `cached_network_image`.
3. ✅ Supabase: проект `lk-system` создан, Auth (email/password) включён, Storage bucket `media` создан (приватный, политики доступа настроим на Этапе 1/3).
4. ✅ `.env` заполнен (`SUPABASE_URL`, `SUPABASE_ANON_KEY` — используется Publishable key), в `.gitignore` (с исключением `.env.example` как шаблона).
5. ✅ Репозиторий на GitHub: [github.com/tiltozavr2545/amicus](https://github.com/tiltozavr2545/amicus) (публичный).
6. ✅ CI: `.github/workflows/ci.yml` — `dart format`, `flutter analyze`, `flutter test` на каждый push/PR, первый прогон прошёл успешно.

## Этап 1 — Auth + профиль

**Статус:** сделано

1. ✅ Экраны регистрации/входа (`sign_in_screen.dart`, `sign_up_screen.dart`) через Supabase Auth SDK; go_router с редиректом по auth-состоянию (`router.dart`).
2. ✅ Таблица `users` создана миграцией, RLS: чтение — всем authenticated, запись/обновление — только своя строка (`auth.uid() = id`). (Чтение позже, в 0.4.0, сужено до «своя строка ИЛИ мой Connection» — см. CLAUDE.md и раздел «Безопасность и приватность» в future-development.md.)
3. ✅ Экран профиля: редактирование имени, выбор и загрузка аватара в приватный bucket `media` (`avatars/{user_id}/...`), отображение через `storage.download()` — SDK сам подставляет access token, ручные signed URL не понадобились. (SELECT-политику Storage на аватарки позже, в 0.5.0, тоже сузили до Connections — см. future-development.md.)
4. ⏸️ CI-job для проверки миграций (`supabase db push --dry-run` в пайплайне) — **не сделано**, отложено. Миграции применяются вручную через Supabase CLI с personal access token (используется только локально, не хранится в репозитории/CI). Для соло-проекта это приемлемо; если станет больно — добавить токен в GitHub Secrets и настроить job.

Секреты передаются в приложение через `--dart-define-from-file=.env` (не `flutter_dotenv`) — так `.env` не нужно объявлять Flutter-ассетом, и CI (`flutter analyze`/`flutter test`) не ломается из-за отсутствия файла с секретами.

## Этап 2 — Connections (знакомства)

**Статус:** сделано

1. ✅ Таблица `invite_links` (code, owner_id, is_used), код генерируется на сервере (`create_invite_link()`, hex из `gen_random_bytes`), а не на клиенте.
2. ✅ Экран «Знакомства» (`connections_screen.dart`): создать/скопировать свой код, ввести и активировать чужой.
3. ✅ RLS: `connections`/`invite_links` не имеют insert/update-политик для обычных пользователей — запись идёт только через security-definer функции `create_invite_link()`/`activate_invite_link()`, что делает «пометить использованным + создать connection» атомарной операцией. Ограничение `user_a_id < user_b_id` + unique-констрейнт исключают дубли и self-connection на уровне схемы.
4. ✅ Тест вручную на двух аккаунтах — пройден на физическом устройстве (Nothing Phone, USB-отладка). Полный цикл (регистрация двух пользователей → код → активация → проверка `connections`/`invite_links`) отработал чисто.
   - По ходу теста нашли и починили два реальных бага: (а) `router.dart` читал auth-статус через закешированный Riverpod-провайдер, который проигрывал гонку с отдельной подпиской `_GoRouterRefreshStream` — вход/выход не редиректили живьём, помогал только полный рестарт приложения; теперь редирект читает `currentSession` напрямую с клиента; (б) создание профиля при регистрации падало под RLS, когда подтверждение email ещё не пройдено (нет сессии → нет `auth.uid()`) — перенесли создание строки `users` в триггер `handle_new_user()` на `auth.users`, не зависящий от наличия сессии.

## Этап 3 — Общая лента

**Статус:** сделано

1. ✅ Таблица `posts` (`posts.author_id` ссылается на `public.users`, не на `auth.users` — так PostgREST может делать embed `.select('*, author:users(name)')` в один запрос), экран создания поста (текст + фото), загрузка в приватный bucket `media` (`posts/{author_id}/...`).
2. ✅ RLS на `posts`: SELECT — автор или его Connection (та же логика, что и в `activate_invite_link`, но как обычная политика, не функция — не нужна атомарность); Storage-политики для `posts/...` зеркалят то же условие.
3. ✅ Лента: pull-to-refresh + бесконечный скролл (keyset-пагинация по `(created_at, id)`, по 20 постов за раз — курсор по последнему посту вместо `range()`-смещения, чтобы вставка/удаление постов сверху между страницами не давала дублей/пропусков; чистая функция `keysetFilter()` в `feed_repository.dart` покрыта юнит-тестами). Фото — через `createSignedUrl` (бакет приватный), URL живёт 24 часа и стабилен на сессию, поэтому кеш `cached_network_image` реально работает.
4. ✅ Протестировано вручную на устройстве: публикация с фото и без, видимость по Connections корректна.
   - Найден и починен баг: `RefreshIndicator` не срабатывал на непустой ленте — стандартная физика скролла не даёт потянуть, если контент не выходит за экран. Добавлен `AlwaysScrollableScrollPhysics`.
   - По фидбеку: добавлен список «Мои знакомые» на экран Connections (потребовал перевести `connections.user_a_id`/`user_b_id` на FK к `public.users` вместо `auth.users` — так же, как раньше сделали для `posts`, чтобы работал embed на обе стороны связи). Кнопка перехода к Connections перенесена с профиля на ленту (теперь это лендинг-экран, профиль — на `/profile`).

## Этап 4 — Реакции и комментарии

**Статус:** сделано

1. ✅ Таблица `reactions` (post_id, user_id, `unique(post_id, user_id)` — повторный лайк невозможен на уровне схемы).
2. ✅ Таблица `comments` (post_id, author_id, text), индекс на `post_id`; `author_id` ссылается на `public.users` — embed имени автора в один запрос, как у постов.
3. ✅ RLS: вместо дублирования логики «автор или Connection» — политики `reactions`/`comments` просто проверяют `exists (select 1 from posts where id = post_id)`; поскольку у `posts` уже есть своя RLS, подзапрос от имени текущего пользователя автоматически возвращает строку только если пост виден. Не нужно чинить в трёх местах, если правила видимости постов изменятся.
4. ✅ Лайк — toggle с оптимистичным обновлением UI (сразу меняется иконка/счётчик, откат при ошибке сети). Комментарии — отдельный экран, плоский список.
5. ⏸️ Supabase Realtime — не добавляли, как и планировалось (необязательно для MVP).
6. ✅ Протестировано вручную на устройстве: лайк/анлайк, комментарии, счётчики — всё корректно.

Счётчик комментариев на странице ленты считается батч-запросом (`comments` с `post_id in (...)`), не по одному запросу на пост. Счётчики реакций с 0.4.0 приходят одним вызовом `security definer`-функции `reaction_summary(uuid[])` (числа + собственная реакция, без чужих `user_id`) — раньше это тоже был батч-запрос по `reactions`, но он отдавал наружу, кто что поставил.

## Этап 5 — Полировка + деплой (mobile-first)

**Статус:** сделано (Android). iOS сознательно отложен за пределы MVP — см. [future-development.md](future-development.md).

1. ✅ Signing config (keystore, `android/key.properties`, не в репозитории) + сборка `.aab`.
2. ✅ Google Play Console → внутреннее тестирование (Internal Testing track) — приложение опубликовано.
3. ✅ Пустые состояния (нет постов/нет знакомых/нет комментариев) — строки `noPostsYetMessage`/`noConnectionsYetMessage`/`noCommentsYetMessage` в `app_en.arb`/`app_ru.arb`.
4. ✅ README с описанием и скриншотами.
5. ⏸️ Демо-видео — сознательно решено не делать.

CI/CD для сборок (Fastlane/Codemagic) осталось ручным процессом — по желанию, не обязательно для портфолио; можно добавить в 1.0, если сборки станут частыми.

Мелкая полировка обработки ошибок (не выводить сырой текст исключения пользователю) осталась как есть — см. раздел «Безопасность и приватность» в future-development.md.

---

## Технические решения по умолчанию

- **State management:** Riverpod
- **Навигация:** go_router
- **Backend SDK:** supabase_flutter
- **Кеширование картинок:** cached_network_image
- **Версионирование схемы БД:** Supabase CLI migrations (не ручные правки в дашборде)
- **Линтинг/форматирование:** flutter_lints + `dart format`, проверяются в CI с первого коммита
- **Структура репозитория:** `docs/` — планирование, `app/` — Flutter-проект (org `com.github.tiltozavr2545`, имя пакета `amicus`)
- **Название проекта:** Amicus (переименовано с рабочего «Круг» после старта разработки — см. project-brief.md)
- **Репозиторий:** [github.com/tiltozavr2545/amicus](https://github.com/tiltozavr2545/amicus) (публичный)
- **Версия Flutter:** закреплена на 3.32.8 (SDK в `~/development/flutter`) — новее нельзя, пока dev-машина на macOS 12; при обновлении macOS до 14+ можно снять пин и перейти на актуальную стабильную версию
- **Supabase API keys:** используется новый формат (Publishable/Secret вместо legacy anon/service_role) — в `SUPABASE_ANON_KEY` кладём именно Publishable key (`sb_publishable_...`); Secret key нигде в клиентском коде не используется

Отклонения от этого списка (например, замена Riverpod на что-то другое) стоит фиксировать здесь, чтобы не расходиться с планом без причины.
