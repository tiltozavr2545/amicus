-- Пути записи в comments перестают отвечать на вопросы про чужие строки.
--
-- Два оракула, оба того же класса, что уже закрывался трижды (20260818130000 —
-- posts.id, 20260819130000/20260819150000 — reactions, 20260821130000 —
-- is_author_of_comment_visible). Оба живут не в политике, а рядом с ней, и
-- поэтому мимо тех правок прошли.
--
-- 1. enforce_comment_reply_rules() (20260725120000) — `security definer`
--    BEFORE INSERT-триггер. Он читает comments БЕЗ RLS и кидает пять разных
--    сообщений. А BEFORE ROW-триггеры в Postgres срабатывают ДО того, как
--    применится `WITH CHECK` политики (ExecBRInsertTriggers идёт раньше
--    ExecWithCheckOptions в ExecInsert) — то есть триггер успевает высказаться
--    про строку, которую политика потом всё равно не пропустит.
--
--    Что это давало. Заблокированный, сохранивший id чужого комментария,
--    отправляет комментарий к видимому ему посту с этим id в
--    `parent_comment_id` и по тексту ошибки читает состояние скрытой строки:
--      'Parent comment not found'                       — строки больше нет
--      'Parent comment belongs to a different post'     — есть, но не тут
--      'Replies cannot be nested more than one level deep' — есть, и это ответ
--      'Cannot reply to a deleted comment'              — есть, и это заглушка
--      42501 от RLS                                     — есть, жива, не видна
--    Пять различимых ответов там, где обязан быть один.
--
--    Починка: триггер молчит про то, чего вызывающий не видит. Не видит —
--    `return new`, и вердикт выносит INSERT-политика, одинаковым 42501 на все
--    случаи разом. Видит — структурные сообщения остаются как были: они
--    рассказывают о строке, которую он и так может прочитать.
--
-- 2. delete_own_comment() (20260726150000) — 'Comment not found' против
--    'Not your comment'. Тот же вопрос «жива ли строка», заданный напрямую.
--    set_post_media() (20260820150000) этот же случай уже решает правильно —
--    один PT404 на «не моё» и на «нет такого». Здесь то же самое.

-- «Виден ли мне этот комментарий» — ровно условие SELECT-политики comments,
-- свёрнутое в строгий boolean (coalesce, тот же урок, что и в 20260821130000:
-- null и false различимы снаружи и сами работают оракулом).
--
-- ЭТО ВТОРАЯ ЗАПИСЬ ТОГО ЖЕ ПРАВИЛА, и это осознанно. Подставить эту функцию
-- в саму SELECT-политику вместо её нынешнего
-- `author_id in (select visible_author_ids())` нельзя: `security definer` не
-- инлайнится планировщиком, и построчный вызов на ленте — ровно та регрессия,
-- ради которой писалась 20260726180000 (217 мс → 3.5 мс). Политика остаётся
-- множественной, функция обслуживает единичные проверки на путях записи, где
-- строка одна и цена вызова не важна.
--
-- Значит, менять надо обе — как у пары is_system_account()/system_account_ids()
-- (20260821160000), которая живёт с тем же уговором. Источник, с которым
-- сверяться: политика "Comments are viewable by the viewer's unmuted
-- connections" (последняя редакция — 20260818170000).
create or replace function public.is_comment_visible(p_comment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select
      -- Пост виден. Внутри `security definer` политика posts не применяется,
      -- поэтому проверка выписана явно тем же некоррелированным множеством,
      -- что и в самой политике.
      exists (
        select 1 from posts p
         where p.id = c.post_id
           and p.author_id in (select public.visible_author_ids())
      )
      and (
        public.is_author_visible(c.author_id)
        or public.is_comment_visible_to_post_owner(c.id)
      )
      and (
        c.parent_comment_id is null
        or public.is_author_of_comment_visible(c.parent_comment_id)
        or public.is_comment_visible_to_post_owner(c.parent_comment_id)
      )
      and (
        c.reply_to_id is null
        or public.is_author_of_comment_visible(c.reply_to_id)
        or public.is_comment_visible_to_post_owner(c.reply_to_id)
      )
    from comments c
    where c.id = p_comment_id
  ), false);
$$;

-- Выдана `authenticated`, потому что стоит в `with check` INSERT-политики ниже,
-- а политика вычисляется с правами ВЫЗЫВАЮЩЕЙ роли (тот самый разбор в
-- 20260726140000 про comment_author). Раскрытием это не является: ответ всегда
-- про самого вызывающего, и «не видно» неотличимо от «нет такой строки».
revoke execute on function public.is_comment_visible(uuid) from public, anon;
grant execute on function public.is_comment_visible(uuid) to authenticated;

-- INSERT-политика начинает требовать, чтобы цель ответа была ВИДНА, а не
-- просто «написана видимым автором».
--
-- Прежние ветки (`is_author_of_comment_visible(x) or
-- is_comment_visible_to_post_owner(x)`, 20260819120000) шире, чем право читать
-- строку: комментарий моего Connection под постом человека, которого я не
-- знаю, проходил их, хотя SELECT-политика такую строку мне не отдаёт. Пока
-- триггер кидал 'Parent comment belongs to a different post', эта щель была
-- закрыта им же — а теперь триггер на невидимой строке молчит, и закрывать её
-- обязана политика. Ни один законный ответ не теряется: пост ответа проверен
-- политикой отдельной веткой, а триггер ниже требует, чтобы пост родителя
-- совпадал с ним.
drop policy "Users can comment on posts and comments they can see" on public.comments;

create policy "Users can comment on posts and comments they can see"
on public.comments for insert
to authenticated
with check (
  author_id = auth.uid()
  and created_at = now()
  and deleted_at is null
  and exists (select 1 from posts p where p.id = comments.post_id)
  and (parent_comment_id is null or public.is_comment_visible(parent_comment_id))
  and (reply_to_id is null or public.is_comment_visible(reply_to_id))
);

create or replace function public.enforce_comment_reply_rules()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  parent record;
  addressee record;
begin
  if new.parent_comment_id is null then
    if new.reply_to_id is not null then
      raise exception 'Only a reply can address another comment';
    end if;
    return new;
  end if;

  -- Не рассказывать ничего про строку, которой вызывающему видеть нельзя:
  -- отдать вердикт INSERT-политике выше. Она отказывает одинаковым 42501 и
  -- когда строки нет, и когда она чужая, и когда это заглушка.
  if not public.is_comment_visible(new.parent_comment_id) then
    return new;
  end if;

  select post_id, parent_comment_id, deleted_at
    into parent
    from comments
   where id = new.parent_comment_id;

  -- Видимость уже проверена, так что сюда доходит только существующая строка.
  -- Ветка остаётся на случай удаления между двумя запросами: политика
  -- перепроверит то же самое и откажет.
  if not found then
    return new;
  end if;

  if parent.post_id <> new.post_id then
    raise exception 'Parent comment belongs to a different post';
  end if;
  if parent.parent_comment_id is not null then
    raise exception 'Replies cannot be nested more than one level deep';
  end if;
  if parent.deleted_at is not null then
    raise exception 'Cannot reply to a deleted comment';
  end if;

  -- Адресат обязан быть внутри этой же ветки: либо корень, либо один из его
  -- ответов. Иначе метка «в ответ» указывала бы на посторонний (возможно,
  -- невидимый) комментарий.
  if new.reply_to_id is not null then
    if not public.is_comment_visible(new.reply_to_id) then
      return new;
    end if;

    select parent_comment_id, deleted_at
      into addressee
      from comments
     where id = new.reply_to_id;

    if not found then
      return new;
    end if;

    if new.reply_to_id <> new.parent_comment_id
       and addressee.parent_comment_id is distinct from new.parent_comment_id then
      raise exception 'Addressed comment belongs to a different thread';
    end if;
    if addressee.deleted_at is not null then
      raise exception 'Cannot reply to a deleted comment';
    end if;
  end if;

  return new;
end;
$$;

-- delete_own_comment(): «не моё» и «нет такого» становятся одним ответом.
--
-- Тело целиком взято из 20260726150000 — миграции, которая трогала эту функцию
-- последней (см. «Грабли» в CLAUDE.md про `create or replace`), и отличается
-- от неё ровно двумя строками: обе ветки теперь кидают один и тот же PT404.
-- `for update` перед проверкой на ответы и `is distinct from` в проверке
-- владения сохранены как были — они про другое.
create or replace function public.delete_own_comment(p_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_author uuid;
  v_parent uuid;
  v_has_replies boolean;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- FOR UPDATE: см. 20260726150000, пункт (2). Обязан быть взят до проверки
  -- на наличие ответов.
  select author_id, parent_comment_id
    into v_author, v_parent
    from comments
   where id = p_comment_id
     for update;

  -- Один код на «нет такого комментария» и на «есть, но чужой». Различать их
  -- значит отвечать на вопрос «жива ли ещё та строка» про комментарий, который
  -- RLS обязана скрывать целиком.
  if not found or v_author is distinct from auth.uid() then
    raise exception 'Comment not found' using errcode = 'PT404';
  end if;

  select exists (
    select 1 from comments where parent_comment_id = p_comment_id
  ) into v_has_replies;

  -- Есть ответы: заглушка, чтобы ветка осталась читаемой.
  if v_has_replies then
    update comments
       set deleted_at = now(),
           text = ''
     where id = p_comment_id;
    return;
  end if;

  delete from comments where id = p_comment_id;

  -- Это был последний ответ под заглушкой? Тогда заглушке больше нечего
  -- держать вместе.
  if v_parent is not null then
    delete from comments
     where id = v_parent
       and deleted_at is not null
       and not exists (
         select 1 from comments r where r.parent_comment_id = v_parent
       );
  end if;
end;
$$;
