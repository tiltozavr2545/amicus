-- Смена реакции перестаёт работать на постах, которых вызывающему не видно.
--
-- INSERT-политика («Users can like posts they can see») с самого начала
-- требовала `exists (select 1 from posts p where p.id = reactions.post_id)` —
-- то есть пост обязан быть виден, иначе реакцию не поставить. У её
-- UPDATE-близнеца («Users can change their own reaction», 20260710140000,
-- дополнен guard'ом в 20260711120000) этого требования не было никогда:
-- `using (user_id = auth.uid())` спрашивает только «моя ли это строка».
--
-- Само по себе это уже позволяет двигать реакцию на посте, который RLS обязана
-- скрывать. Но хуже другое: на этом же неявном условии держится guard
-- `dislikes_disabled`.
--
-- Guard написан как `not (type = 'dislike' and exists (select … from posts p
-- join users u …))`, и этот `exists` выполняется правами ВЫЗЫВАЮЩЕГО, то есть
-- сам фильтруется политикой posts. Если пост вызывающему не виден, подзапрос
-- не находит ничего, и guard делает вывод «флага нет» вместо «не могу
-- проверить». Ровно тот класс ошибки, что и в 20260715150000, где подзапрос к
-- blocked_users фильтровался политикой blocked_users и ветка «меня
-- заблокировали» молча отваливалась (см. «Грабли» в CLAUDE.md: RLS
-- применяется и к подзапросам внутри политики).
--
-- Спрятать от себя чужой пост можно самому, ничьего участия не требуется —
-- достаточно мьюта. Воспроизведено симуляцией на живой схеме ДО правки (роль
-- `authenticated`, `request.jwt.claims`, транзакция с rollback):
--
--   post_visible_before           = 1        -- пост виден, лайк стоит
--   my_reaction_before            = like
--   post_visible_after_mute       = 0        -- мьютим автора, пост исчез
--   my_reaction_after_update      = dislike  -- ДЫРА: guard пропустил
--   dislike_count_seen_by_author  = 1        -- reaction_summary() — definer,
--                                            -- считает мимо RLS, автор увидит
--
-- То есть обход ровно того, что 20260711120000 объявляла закрытым («so the UI
-- can't be bypassed by a direct API call») и что 20260821110000 уже
-- восстанавливала — но только на INSERT-ветке, потому что искала потерянный
-- guard, а не условие, на котором он стоит.
--
-- Починка — доставить в UPDATE то самое требование видимости, которое есть в
-- INSERT. Оно нужно в обеих половинах политики, и по разным причинам:
--
--   * в `using` — чтобы строка на невидимом посте вообще не попадала под
--     UPDATE. Оракула это не создаёт: «поста не видно» и «реакции нет» дают
--     одинаковые 0 строк без ошибки, и оба ответа про самого вызывающего;
--   * в `with check` — чтобы guard'у было на что опереться. Пост виден ⟹ его
--     автор это сам вызывающий, системный аккаунт либо незамьюченный и
--     незаблокированный Connection ⟹ users-политика все три случая пропускает,
--     значит подзапрос guard'а больше не может молча не найти ничего.
--
-- `created_at = now()` в UPDATE-ветку НЕ добавляется, в отличие от INSERT:
-- pin_reaction_identity() (20260819150000) намеренно возвращает `created_at` к
-- старому значению на каждом апдейте, так что такое условие отвергало бы любую
-- законную смену реакции.
--
-- DELETE-политика не трогается намеренно: снять свою реакцию с поста, который
-- стал невидимым, — законное действие, и запрещать его нечего.
--
-- Политика собирается целиком (`drop` + `create`) — иначе часть `with check`
-- не поменять; тело guard'а взято дословно из 20260711120000, миграции,
-- которая трогала эту политику последней.

drop policy "Users can change their own reaction" on public.reactions;

create policy "Users can change their own reaction"
on public.reactions for update
to authenticated
using (
  user_id = auth.uid()
  and exists (select 1 from posts p where p.id = reactions.post_id)
)
with check (
  user_id = auth.uid()
  and exists (select 1 from posts p where p.id = reactions.post_id)
  and not (
    reactions.type = 'dislike'
    and exists (
      select 1
      from posts p
      join users u on u.id = p.author_id
      where p.id = reactions.post_id and u.dislikes_disabled
    )
  )
);
