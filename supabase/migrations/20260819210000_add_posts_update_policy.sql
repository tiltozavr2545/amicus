-- Первая UPDATE-политика на posts вообще — до сих пор редактирования постов
-- не было (см. data-model.md: у comments UPDATE нет намеренно, у posts его
-- просто никогда не заводили). Разрешено менять только text; author_id,
-- created_at, id, client_token должны остаться недостижимы через этот путь.
--
-- Выбран узкий грант по колонке, а не BEFORE UPDATE триггер вроде
-- pin_reaction_identity() (20260819150000): тот триггер был нужен, потому что
-- клиентский upsert на reactions шлёт весь payload (post_id/user_id) на
-- каждый вызов, и сузить грант значило бы сломать легитимный upsert. Здесь
-- клиент дёргает точечный `update({'text': ...}).eq('id', postId)` — не
-- upsert, не резолвит остальные колонки — так что грант `(text)` ничему не
-- мешает и дешевле в поддержке, чем ещё один триггер.
--
-- Existence-oracle: `using (author_id = auth.uid())` фильтрует строки ДО
-- проверки with check, так что PATCH на чужой (в том числе скрытый RLS) пост
-- матчит 0 строк — неотличимо от "пост не существует". В отличие от истории
-- reactions (0.13.1/0.13.2), здесь только два исхода: "моя строка обновилась"
-- и "ничего не обновилось", третьего — "чужая строка задета, но невидима" —
-- быть не может, потому что and в with check дублирует то же условие.
create policy "Users can edit their own posts"
on public.posts for update
to authenticated
using (author_id = auth.uid())
with check (author_id = auth.uid());

revoke update on public.posts from authenticated;
grant update (text) on public.posts to authenticated;
