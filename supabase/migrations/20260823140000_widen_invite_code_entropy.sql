-- Инвайт-код становится 128-битным вместо 40-битного.
--
-- `encode(gen_random_bytes(5), 'hex')` — это 10 шестнадцатеричных символов,
-- то есть 2^40 ≈ 1.1e12 вариантов. Для кода, который живёт пять минут в чате,
-- этого хватило бы; этот живёт до тех пор, пока его не активируют или не
-- отзовут через rotate_invite_link(), и предъявительский: кто активировал, тот
-- и Connection, а Connection видит ленту, профиль и всю галерею фотографий.
--
-- Перебор идёт не по одному конкретному коду, а сразу по всему пулу
-- невостребованных: при N живых кодах ожидаемая работа — 2^40/N попыток, и
-- activate_invite_link() (20260726170000) не делает ничего, чтобы это
-- замедлить — ни задержки, ни счётчика неудач, ни блокировки. Попадание даёт
-- доступ к аккаунту случайного человека.
--
-- 16 байт — размер, на котором такие рассуждения заканчиваются совсем, а не
-- отодвигаются. Заодно исчезает вторая мелочь: у 40 бит день рождения
-- наступает примерно на миллионе кодов, и `invite_links_code_key` мог бы
-- отбить легальную выдачу коллизией — цикла с повтором в функциях нет. На 128
-- битах цикл не нужен.
--
-- Цена — длина: код становится 32 символа вместо 10. Он и раньше был
-- рассчитан на «скопировать и переслать» (на экране SelectableText с кнопкой
-- копирования, connections_screen.dart), так что вводить его руками и раньше
-- никто не собирался.
--
-- Существующие коды не трогаются. Девять использованных мертвы — активировать
-- их второй раз нельзя (PT409), их длина уже ничего не значит. Живой
-- невостребованный код на момент миграции ровно один; переписать его здесь
-- значило бы молча отозвать код, который владелец мог кому-то отправить, а
-- это его решение, а не миграции. Отзывается он кнопкой «создать новый код»,
-- которая для того и заведена (20260822150000).
--
-- Тела обеих функций взяты из миграций, которые трогали их последними, —
-- 20260709134154 для create_invite_link() и 20260822150000 для
-- rotate_invite_link(), — и отличаются от них ровно одной цифрой. См. «грабли»
-- про `create or replace` в CLAUDE.md.

create or replace function public.create_invite_link()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text;
  v_existing text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  -- Already have an unused invite? Hand back the same code instead of
  -- minting a new one (idempotent, and the client just displays whatever
  -- code comes back, so no app-side change needed).
  select code into v_existing
  from invite_links
  where owner_id = auth.uid() and not is_used
  limit 1;

  if v_existing is not null then
    return v_existing;
  end if;

  v_code := encode(gen_random_bytes(16), 'hex');

  insert into invite_links (owner_id, code)
  values (auth.uid(), v_code);

  return v_code;
end;
$$;

create or replace function public.rotate_invite_link()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  delete from invite_links
   where owner_id = auth.uid()
     and not is_used;

  v_code := encode(gen_random_bytes(16), 'hex');

  insert into invite_links (owner_id, code)
  values (auth.uid(), v_code);

  return v_code;
end;
$$;
