-- Инвайт-код перестаёт сгорать, когда связь уже существовала.
--
-- `activate_invite_link()` вставляет строку `connections` через
-- `on conflict (user_a_id, user_b_id) do nothing`, а `is_used = true` ставит
-- следом БЕЗУСЛОВНО. Если A и B уже связаны, вставка не делает ничего, а код
-- всё равно помечается использованным — и `invite_links_one_active_per_owner`
-- перестаёт видеть у A активную строку.
--
-- Это не теоретический случай. `.timeout()` перестаёт ждать, не отменяя
-- запрос, поэтому первая активация регулярно коммитится уже после того, как
-- экран показал ошибку; человек жмёт «Активировать» ещё раз — и вторая
-- попытка попадает в `is_used`, то есть в `PT409` «код уже использован».
-- Хуже другой заход: код переслали в общий чат, там его увидел кто-то, кто с A
-- и так на связи, вставил из любопытства — и код A, предназначавшийся третьему
-- человеку, кончился. Экран при этом рапортует успех, потому что связь
-- действительно есть, так что A узнаёт о пропаже только когда решит отправить
-- код по назначению.
--
-- Цена ошибки несимметрична. Код предъявительский: кто активировал, тот и
-- Connection с полной видимостью ленты, профиля и галереи. Поэтому «сгорел
-- впустую» лечится не «выдадим ещё один на всякий случай», а «жжём только
-- тогда, когда он действительно что-то сделал».
--
-- `get diagnostics ... = row_count` после `insert ... on conflict do nothing`
-- отдаёт число ВСТАВЛЕННЫХ строк, то есть 0 при конфликте, — это и есть
-- искомое «связь завёл именно этот вызов».
--
-- Повторная активация тем же уже-связанным человеком остаётся безобидным
-- no-op: строка не вставится, код не сгорит, наружу уйдёт та же строка
-- владельца. Различать эти два исхода в ответе намеренно не стали — «вы
-- теперь на связи с X» верно в обоих, а отдельный код ошибки сообщал бы
-- предъявителю, состоит ли владелец кода в связи с ним, то есть отвечал бы на
-- вопрос про чужой граф связей.

create or replace function public.activate_invite_link(p_code text)
returns table (owner_id uuid, owner_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_invite invite_links%rowtype;
  v_connected int;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_invite
  from invite_links
  where code = p_code
  for update;

  if not found then
    raise exception 'Invite code not found' using errcode = 'PT404';
  end if;

  if v_invite.is_used then
    raise exception 'Invite code already used' using errcode = 'PT409';
  end if;

  if v_invite.owner_id = auth.uid() then
    raise exception 'Cannot activate your own invite link' using errcode = 'PT422';
  end if;

  insert into connections (user_a_id, user_b_id, method)
  values (least(v_invite.owner_id, auth.uid()), greatest(v_invite.owner_id, auth.uid()), 'invite_link')
  on conflict (user_a_id, user_b_id) do nothing;

  get diagnostics v_connected = row_count;

  if v_connected > 0 then
    update invite_links
    set is_used = true, used_by_id = auth.uid()
    where id = v_invite.id;
  end if;

  return query
  select u.id, u.name from users u where u.id = v_invite.owner_id;
end;
$$;
