-- Возврат guard'а dislikes_disabled в INSERT-политику reactions.
--
-- 20260819130000 пересоздавала эту политику ради пиннинга created_at и
-- переписала `with check` с нуля, не перенеся проверку из 20260711120000:
--
--   and not (
--     reactions.type = 'dislike'
--     and exists (select 1 from posts p join users u on u.id = p.author_id
--                  where p.id = reactions.post_id and u.dislikes_disabled)
--   )
--
-- UPDATE-близнец («Users can change their own reaction») эту проверку
-- сохранил, потому что его та миграция не трогала. В итоге правило жило
-- наполовину: тот, кто ещё не реагировал на пост, ставил dislike защищённому
-- автору обычным POST /rest/v1/reactions и попадал в reaction_summary();
-- тот, у кого реакция уже стояла, получал отказ на UPDATE-ветке. Одно и то же
-- действие двух пользователей вело себя по-разному — ровно тот обход, который
-- 20260711120000 объявляла закрытым («so the UI can't be bypassed by a direct
-- API call»).
--
-- Проверено симуляцией до правки: для реального поста защищённого автора
-- текущий `with check` даёт true, выражение с guard'ом — false.
--
-- Политика собирается целиком (`drop` + `create`), а не патчится: изменить
-- часть `with check` иначе нельзя, и это же был механизм, которым проверку
-- потеряли. Оба ограничения 20260819130000 — `created_at = now()` и колоночный
-- грант без `id` — сохранены дословно.

drop policy "Users can like posts they can see" on public.reactions;

create policy "Users can like posts they can see"
on public.reactions for insert
to authenticated
with check (
  user_id = auth.uid()
  and created_at = now()
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
