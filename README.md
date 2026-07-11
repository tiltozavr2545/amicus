# Amicus

> Соцсеть-лента, где ты видишь посты только тех людей, с которыми познакомился по-настоящему — через личную встречу или приглашение от друга.

Пилотный/портфолио-проект (изначально шёл под рабочим названием «Круг»). Полное описание идеи, механики и модели данных — в [docs/project-brief.md](docs/project-brief.md).

## Что уже работает (MVP)

- Регистрация и вход (Supabase Auth)
- Профиль: имя, аватар
- Invite-ссылки → «знакомства» (Connections), список знакомых
- Общая лента: посты с текстом и/или фото, пагинация
- Реакции на посты (👍 / 😐 / 👎, одна на пост) и плоские комментарии
- Удаление своих постов и комментариев

Подробный статус по этапам — в [docs/implementation-plan.md](docs/implementation-plan.md).

## Скриншоты

<table>
<tr>
<td><img src="docs/screenshots/feed.png" width="200" alt="Общая лента"><br><sub>Лента</sub></td>
<td><img src="docs/screenshots/comments.png" width="200" alt="Комментарии"><br><sub>Комментарии</sub></td>
<td><img src="docs/screenshots/connections.png" width="200" alt="Знакомства"><br><sub>Знакомства</sub></td>
<td><img src="docs/screenshots/profile.png" width="200" alt="Профиль"><br><sub>Профиль</sub></td>
</tr>
</table>

## Стек

- **Frontend:** Flutter / Dart (Android; iOS отложен — см. [docs/project-brief.md](docs/project-brief.md))
- **Backend:** [Supabase](https://supabase.com) — PostgreSQL, Auth, Storage, Row Level Security
- **State management:** Riverpod
- **Навигация:** go_router
- **CI:** GitHub Actions (`dart format`, `flutter analyze`, `flutter test` на каждый push/PR)

Архитектура доступа к данным целиком построена на RLS-политиках Postgres: увидеть чужой пост или комментарий можно только если между пользователями есть подтверждённое «знакомство» — это проверяется на уровне базы, а не в коде приложения. Профили видны только тебе и твоим связям (перечислить всех пользователей через API нельзя), а по реакциям наружу отдаются только агрегированные счётчики — кто именно что поставил, не узнать (счётчики считает `security definer`-функция, возвращающая числа без чужих `user_id`).

## Структура репозитория

```
app/                  — Flutter-приложение
  lib/features/       — auth, profile, connections, feed
supabase/migrations/  — версионированная схема БД и RLS-политики
docs/                 — бриф, план реализации, отложенные фичи
```

## Запуск локально

```bash
cd app
flutter pub get
flutter run --dart-define-from-file=.env
```

`.env` не хранится в репозитории — нужен свой Supabase-проект (`SUPABASE_URL`, `SUPABASE_ANON_KEY`), см. `app/.env.example`.

## Документация

- [Бриф проекта](docs/project-brief.md) — идея, механика, MVP-скоуп
- [План реализации](docs/implementation-plan.md) — пошаговый прогресс по этапам
- [Отложенные фичи](docs/future-development.md) — комнаты, несколько реакций, треды в комментариях и т.д.
