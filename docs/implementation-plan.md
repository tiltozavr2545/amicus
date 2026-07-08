# Implementation Plan: «Круг» (MVP)

Пошаговый план реализации MVP из [project-brief.md](project-brief.md), с CI и деплоем, встроенными в этапы, а не отложенными на конец. Проект mobile-first (Android + iOS через Flutter), web не рассматривается.

## Прогресс

- [x] Этап 0 — Подготовка + скелет CI
- [x] Этап 1 — Auth + профиль
- [x] Этап 2 — Connections (знакомства)
- [ ] Этап 3 — Общая лента
- [ ] Этап 4 — Реакции и комментарии
- [ ] Этап 5 — Полировка + деплой

---

## Этап 0 — Подготовка + скелет CI

**Статус:** сделано

1. ✅ Flutter SDK установлен — **версия закреплена на 3.32.8**: последняя (3.44.x) требует macOS 14+, а на этой машине macOS 12.7.6 (Monterey). Более новые версии ставить нельзя, пока не обновится macOS. SDK лежит в `~/development/flutter`, добавлен в PATH через `~/.zshrc`.
   - ✅ Android toolchain: Android Studio + cmdline-tools установлены, лицензии приняты, `flutter doctor` зелёный по Android.
   - ⏸️ Xcode: не устанавливается — решено делать сначала только Android, iOS отложен до обновления macOS (см. project-brief.md).
2. ✅ `flutter create --platforms=android,ios` в `app/` (org `com.github.tiltozavr2545`), подключены `supabase_flutter`, `go_router`, `flutter_riverpod`, `cached_network_image`.
3. ✅ Supabase: проект `lk-system` создан, Auth (email/password) включён, Storage bucket `media` создан (приватный, политики доступа настроим на Этапе 1/3).
4. ✅ `.env` заполнен (`SUPABASE_URL`, `SUPABASE_ANON_KEY` — используется Publishable key), в `.gitignore` (с исключением `.env.example` как шаблона).
5. ✅ Репозиторий на GitHub: [github.com/tiltozavr2545/lk-system](https://github.com/tiltozavr2545/lk-system) (публичный).
6. ✅ CI: `.github/workflows/ci.yml` — `dart format`, `flutter analyze`, `flutter test` на каждый push/PR, первый прогон прошёл успешно.

## Этап 1 — Auth + профиль

**Статус:** сделано

1. ✅ Экраны регистрации/входа (`sign_in_screen.dart`, `sign_up_screen.dart`) через Supabase Auth SDK; go_router с редиректом по auth-состоянию (`router.dart`).
2. ✅ Таблица `users` создана миграцией, RLS: чтение — всем authenticated, запись/обновление — только своя строка (`auth.uid() = id`).
3. ✅ Экран профиля: редактирование имени, выбор и загрузка аватара в приватный bucket `media` (`avatars/{user_id}/...`), отображение через `storage.download()` — SDK сам подставляет access token, ручные signed URL не понадобились.
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

**Статус:** не начато

1. Таблица `posts`, экран создания поста (текст + фото), загрузка в Storage.
2. RLS на `posts`: SELECT только если автор — Connection текущего пользователя (или сам пользователь).
3. Лента: список с pull-to-refresh, пагинация (`range()` в Supabase запросе, не грузить всё разом).
4. `cached_network_image` для фото — иначе лента будет мигать/перезагружать картинки.

## Этап 4 — Реакции и комментарии

**Статус:** не начато

1. Таблица `reactions` (post_id, user_id, unique constraint на пару — защита от повторного лайка на уровне БД, не только UI).
2. Таблица `comments` (post_id, author_id, text) — группировка по `post_id`, индекс на `post_id` для быстрой выборки списка комментариев конкретного поста.
3. RLS зеркалит `posts`: видеть комментарии/реакции может тот, кто видит сам пост.
4. Опционально уже здесь: Supabase Realtime подписка на `comments`/`reactions`, чтобы лента обновлялась без ручного refresh — красиво для демо, но не критично для MVP, можно добавить и позже.

## Этап 5 — Полировка + деплой (mobile-first)

**Статус:** не начато

Деплой — это не финальный клик, а отдельная работа с обеими платформами.

**Android:**
1. Настроить signing config (keystore), собрать `.aab`.
2. Google Play Console → внутреннее тестирование (Internal Testing track) — не нужен полный ревью Google, доступно сразу.

**iOS:**
1. Apple Developer аккаунт (платный, $99/год — единственная точка, где потребуются деньги).
2. Xcode archive → App Store Connect → TestFlight, добавить себя/друзей как тестеров.

**CI/CD для сборок (по желанию, не обязательно для портфолио):** можно оставить ручную сборку через Android Studio/Xcode для v1 — автоматизация подписи и публикации через Fastlane/Codemagic имеет смысл добавить в v1.5, когда сборки станут частыми. Для одного релиза ради портфолио ручной процесс проще для новичка и не потребует отладки CI-специфичных проблем с сертификатами.

**Остальная полировка:** пустые состояния (нет постов/нет знакомых), обработка ошибок сети, README с скриншотами, короткое демо-видео.

---

## Технические решения по умолчанию

- **State management:** Riverpod
- **Навигация:** go_router
- **Backend SDK:** supabase_flutter
- **Кеширование картинок:** cached_network_image
- **Версионирование схемы БД:** Supabase CLI migrations (не ручные правки в дашборде)
- **Линтинг/форматирование:** flutter_lints + `dart format`, проверяются в CI с первого коммита
- **Структура репозитория:** `docs/` — планирование, `app/` — Flutter-проект (org `com.github.tiltozavr2545`, имя пакета `krug`)
- **Репозиторий:** [github.com/tiltozavr2545/lk-system](https://github.com/tiltozavr2545/lk-system) (публичный)
- **Версия Flutter:** закреплена на 3.32.8 (SDK в `~/development/flutter`) — новее нельзя, пока dev-машина на macOS 12; при обновлении macOS до 14+ можно снять пин и перейти на актуальную стабильную версию
- **Supabase API keys:** используется новый формат (Publishable/Secret вместо legacy anon/service_role) — в `SUPABASE_ANON_KEY` кладём именно Publishable key (`sb_publishable_...`); Secret key нигде в клиентском коде не используется

Отклонения от этого списка (например, замена Riverpod на что-то другое) стоит фиксировать здесь, чтобы не расходиться с планом без причины.
