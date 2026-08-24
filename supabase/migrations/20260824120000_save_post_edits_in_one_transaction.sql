-- Правка поста — одной транзакцией, и вместе с ней инвариант «текст или медиа»
-- на пути РЕДАКТИРОВАНИЯ.
--
-- 20260823120000 свела публикацию к одному вызову и заодно смогла наконец
-- проверить условие, которое до неё не выражалось: пост обязан иметь текст либо
-- медиа. На пути правки условия по-прежнему нет. `updatePost` шлёт две
-- независимые команды — `PATCH posts {text}` и `rpc set_post_media` — то есть
-- две транзакции, и единственное, что мешает им оставить пост совсем пустым, —
-- это `if (text.isEmpty && _slots.isEmpty)` в композере. Всё, что ходит по тем
-- же двум эндпоинтам мимо экрана, оставляет пустую карточку в ленте у каждого
-- знакомого, и убирает её только `purge_empty_posts()` — следующим часовым
-- тиком, то есть удаляя пост автора у него из-под рук вместо того, чтобы
-- отказать в правке.
--
-- ПОЧЕМУ ПРОВЕРКА НЕ ВСТАВЛЕНА В set_post_media(). Это была первая мысль, и она
-- ломает то, что стоит в Play. `set_post_media()` видит только медиа; про текст
-- ей пришлось бы читать `posts.text`, а он к моменту вызова уже либо новый, либо
-- ещё старый — в зависимости от того, в каком порядке клиент шлёт две команды.
-- Порядок «сначала текст» появился только в build 42 (см. заметку про
-- load-bearing ordering на самом updatePost); build 41, который сейчас и стоит
-- у всех (`select min(app_build) from device_tokens` = 41), шлёт `set_post_media`
-- ПЕРВЫМ. Для него правка «убрать все фотографии и вместо них написать текст»
-- пришла бы в функцию как «медиа пусто, текст ещё null» — то есть законное
-- редактирование начало бы падать с PT422 у всех установленных сборок, и ретрай
-- бы не помог.
--
-- Поэтому не проверка внутри старой функции, а новая точка входа, у которой
-- обе половины на руках сразу. Тот же приём и тот же довод, что у
-- 20260823120000 для публикации: пока половины приезжают порознь, условие
-- непроверяемо; как только они приезжают вместе — проверяемо в одном месте.
--
-- Побочно закрывается то, что комментарий на `updatePost` уже называет своим
-- именем: «What is still not atomic is the pair itself» — текст, доехавший без
-- медиа, оставлял пост наполовину отредактированным, а экран сообщал об ошибке.
-- Теперь это одна транзакция.
--
-- set_post_media() НЕ трогается и никуда не девается: по ней ходит build 41, и
-- снимать грант нельзя ровно по тому же правилу, по которому 20260823120000
-- оставила старые гранты на прямой INSERT в posts/post_media. Убрать её можно
-- будет, когда `min(app_build)` перевалит за сборку с этой функцией.
--
-- Внутри вызывается она же, а не переписанная копия её тела: правило «какие
-- пути осиротели» и проверка префикса должны остаться в одном месте, иначе это
-- ровно та вторая копия, про которую предупреждает CLAUDE.md. Владение постом
-- проверяется здесь отдельно и до неё — `security definer` проносит UPDATE ниже
-- мимо политики "Users can edit their own posts", так что это единственное, что
-- отделяет чужой пост от своего. Код ошибки тот же PT404, что и у
-- set_post_media(): «не мой» и «не существует» обязаны быть неотличимы.

create or replace function public.update_post_with_media(
  p_post_id uuid,
  p_text text default null,
  p_items jsonb default '[]'::jsonb
)
returns table (storage_path text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_text text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from posts p where p.id = p_post_id and p.author_id = auth.uid()
  ) then
    raise exception 'Post not found' using errcode = 'PT404';
  end if;

  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Media list must be an array' using errcode = 'PT422';
  end if;

  -- Тот же nullif(btrim(...)), что в create_post_with_media() и в
  -- posts_text_not_blank (20260822200000): пустая строка от клиента — это
  -- отсутствие текста, а не текст.
  v_text := nullif(btrim(coalesce(p_text, '')), '');

  if v_text is null and jsonb_array_length(p_items) = 0 then
    raise exception 'A post needs text or media' using errcode = 'PT422';
  end if;

  update posts set text = v_text where id = p_post_id;

  -- Остальное — включая проверку префикса путей, лимит в 20 элементов и расчёт
  -- осиротевших объектов — принадлежит set_post_media() и остаётся там.
  return query select s.storage_path from public.set_post_media(p_post_id, p_items) s;
end;
$$;

-- Оба содержательных аргумента про собственный пост вызывающего: владение
-- проверено внутри и до любой записи. См. «Каждая функция в public — эндпоинт
-- PostgREST» в CLAUDE.md.
revoke execute on function public.update_post_with_media(uuid, text, jsonb) from public, anon;
grant execute on function public.update_post_with_media(uuid, text, jsonb) to authenticated;
