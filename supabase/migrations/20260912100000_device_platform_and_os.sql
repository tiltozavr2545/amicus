-- =====================================================================
-- Платформа и версия ОС установки.
--
-- Ложится поверх 20260826000000 (baseline), где `device_tokens` уже несёт
-- `app_version`/`app_build`. Мотив тот же, что был у них, и следующий
-- вопрос той же серии: строка описывает УСТАНОВКУ, и до сих пор она не
-- могла ответить, на чём эта установка стоит. Отсюда не выводилось ни
-- «этот баг только на iOS», ни «разослать тем, кто на Android» — а
-- расхождение номера сборки (устройства сообщали build на единицу выше
-- pubspec) нельзя было даже локализовать по платформе.
--
-- Обе колонки nullable, и это не оплошность: их заполняет клиент, а
-- выложенные версии про них не знают и никогда не узнают. NULL здесь
-- значит «клиент не умеет сообщить», ровно как у `app_build` (см.
-- «Версия приложения и уведомление об обновлении» в docs/data-model.md).
-- Поэтому же оба CHECK пропускают NULL: жёсткая проверка на колонке,
-- которую пишет фоновый upsert, отказом уронила бы САМУ регистрацию
-- пуш-токена — молча и вместе со всеми уведомлениями. Клиент приводит
-- значения к принимаемому виду сам (`shared/device_os.dart`), той же
-- парой «нормализация на клиенте + CHECK на сервере», что и версия.
--
-- `platform` — перечисление, а не свободный текст: это ключ, по которому
-- будут собираться аудитории, и «iOS»/«ios»/«iPhone» в одной колонке
-- превратят любой group by в ложь. Список — ровно то, что умеет вернуть
-- `Platform.operatingSystem` в Dart, плюс `web` (его `dart:io` не
-- отвечает вовсе, а веб-версия лежит в отложенном). Добавлять сюда
-- значение — миграцией, чтобы оно не появилось само.
--
-- `os_version` — только цифры и точки (`18.1`, `15`), без сырого ответа
-- платформы. iOS отвечает `Version 18.1 (Build 22B83)`, Android —
-- `Android 15 (API 35)`; хранить это дословно значит переложить разбор на
-- каждого читателя навсегда, а идентификатор сборки внутри ближе к
-- отпечатку устройства, чем к чему-то полезному. Три части — потолок:
-- `15.1.2.3` придёт как `15.1.2`, а не отказом.
--
-- Гранты: INSERT на device_tokens выдан ПОКОЛОНОЧНО (baseline, строка
-- `grant insert (app_build, app_version, fcm_token, locale, user_id)`),
-- поэтому новые колонки обязаны быть упомянуты явно — иначе upsert с ними
-- отлетает по правам, и это снова тихая потеря регистрации токена. UPDATE
-- выдан на таблицу целиком, его трогать не нужно.
-- =====================================================================

alter table public.device_tokens
  add column platform text,
  add column os_version text;

alter table public.device_tokens
  add constraint device_tokens_platform_check
  check (platform is null or platform = any (array[
    'android'::text, 'ios'::text, 'macos'::text,
    'windows'::text, 'linux'::text, 'fuchsia'::text, 'web'::text
  ]));

alter table public.device_tokens
  add constraint device_tokens_os_version_format
  check (os_version is null or os_version ~ '^[0-9]+(\.[0-9]+){0,2}$');

grant insert (platform, os_version) on table public.device_tokens to authenticated;

comment on column public.device_tokens.platform is
  'ОС установки: android/ios/… NULL = клиент старее этой колонки.';
comment on column public.device_tokens.os_version is
  'Версия ОС цифрами: 18.1, 15. Нормализуется клиентом (shared/device_os.dart).';
