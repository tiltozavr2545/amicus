-- Множественные фото/видео на пост: таблица post_media заменяет одиночный
-- posts.image_path (тот пока остаётся — переносится и удаляется отдельной,
-- последующей миграцией, только когда клиент, читающий post_media, уже
-- раскатан; см. implementation-plan/переписку в истории задачи).
--
-- Одна строка — один медиа-элемент. position задаёт порядок отображения в
-- карусели ленты; это чисто клиентский порядок отображения, а не плотная
-- последовательность 0..N-1 — при редактировании клиент переписывает
-- position всех оставшихся строк поста разом (delete+insert), поэтому дыры
-- не образуются, но и не гарантируются отсутствующими. Ширина/высота/
-- длительность сознательно не хранятся: ни карусель (BoxFit.cover), ни
-- постер видео их не требуют, а спекулятивные колонки — лишняя вещь,
-- которую придётся держать в синхроне без реальной необходимости.
create table public.post_media (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts (id) on delete cascade,
  position smallint not null,
  media_type text not null check (media_type in ('image', 'video')),
  storage_path text not null,
  -- Только для video: путь до постера (JPEG первого кадра), сгенерированного
  -- на клиенте при выборе файла. Null для image.
  poster_path text,
  created_at timestamptz not null default now(),
  -- Порядок отображения внутри поста не может повторяться.
  constraint post_media_post_position_key unique (post_id, position),
  -- Идемпотентность повторной попытки batch-вставки: тот же (post_id,
  -- storage_path) — тот же логический элемент, INSERT с
  -- ignoreDuplicates повторную попытку превращает в no-op, как и для
  -- posts/comments через (author_id, client_token).
  constraint post_media_post_storage_path_key unique (post_id, storage_path)
);

alter table public.post_media enable row level security;

-- Видимость медиа целиком наследуется от видимости самого поста — то же
-- правило, что и у storage-политики на фото постов и у posts.select, через
-- некоррелированный `in (select visible_author_ids())`, а не построчный
-- вызов is_author_visible() (см. «Грабли» в CLAUDE.md — построчный вызов
-- security definer не инлайнится планировщиком).
create policy "Post media are viewable by author and their connections"
on public.post_media for select
to authenticated
using (
  exists (
    select 1 from public.posts p
    where p.id = post_media.post_id
      and p.author_id in (select public.visible_author_ids())
  )
);

-- created_at пинится по значению (как posts/comments в 20260726190000) —
-- дешевле в поддержке, чем сужать грант ради одной колонки с известным
-- инвариантом. author_id проверяется через join к posts, а не хранится на
-- самой строке — у post_media нет своего author_id, только post_id.
create policy "Users can attach media to their own posts"
on public.post_media for insert
to authenticated
with check (
  created_at = now()
  and exists (
    select 1 from public.posts p
    where p.id = post_media.post_id
      and p.author_id = auth.uid()
  )
);

create policy "Users can delete media from their own posts"
on public.post_media for delete
to authenticated
using (
  exists (
    select 1 from public.posts p
    where p.id = post_media.post_id
      and p.author_id = auth.uid()
  )
);

-- Нет UPDATE-политики намеренно. Замена файла и изменение порядка при
-- редактировании поста моделируются как delete+insert строк (storage-объект
-- при reorder не трогается — та же storage_path переиспользуется в новой
-- строке с новым id/position), а не как update на месте. Одно меньше
-- "что можно менять на этой строке" для аудита.

-- id не грантован клиенту (existence-oracle — тот же приём, что и для
-- posts.id/comments.id в 20260818130000: сервер генерирует id сам,
-- клиенту он не нужен ни в одном пути записи).
revoke insert on public.post_media from authenticated;
grant insert (post_id, position, media_type, storage_path, poster_path, created_at)
  on public.post_media to authenticated;

-- Лимит 20 медиа на пост — backstop, не основной UX-гейт (экран публикации
-- сам блокирует добавление на 20-м элементе). Нужен, чтобы подделанный
-- запрос не смог прицепить неограниченное число строк к посту — раздувая
-- storage и стоимость рендера ленты. CHECK не годится: Postgres не умеет
-- cross-row проверки внутри CHECK. security definer не нужен: функция
-- считает по той же таблице, в которую пишет вызывающий, и его собственная
-- INSERT-политика уже даёт ему видимость этих строк — RLS-рекурсии, которая
-- оправдывала бы security definer (как для is_blocked_pair, читающего
-- ЧУЖИЕ таблицы), здесь нет.
create or replace function public.enforce_post_media_limit()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.post_media where post_id = new.post_id) >= 20 then
    raise exception 'post_media_limit_exceeded' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

create trigger post_media_enforce_limit_before_insert
before insert on public.post_media
for each row execute function public.enforce_post_media_limit();
