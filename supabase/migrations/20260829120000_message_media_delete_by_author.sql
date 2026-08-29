-- =====================================================================
-- Вложения сообщения сносит их автор — и после того, как вышел из комнаты.
--
-- Ложится поверх 20260829110000. Продолжение того же аудита: находка про
-- удаление аккаунта оказалась не клиентской, как выглядела, а упиралась
-- сюда.
--
-- ЧТО БЫЛО. DELETE-политика префикса `messages/` требовала ДВУХ вещей:
-- членства в комнате (`foldername[2] in my_room_ids()`) и авторства
-- (`foldername[3] = auth.uid()`). Второе — это и есть право: путь
-- `messages/<room_id>/<author_id>/…` пришпилен к вызывающему третьим
-- сегментом, и чужой байт через него не достать при любом членстве. А
-- первое ничего не добавляет к безопасности и отнимает ровно те два случая,
-- где удаление и нужно:
--
--   1. **Удаление аккаунта.** `deleteAccount()` обязан сносить строки раньше
--      объектов (`deleteRowsThenObjects` — иначе отказавший RPC оставляет
--      живой аккаунт без единой своей фотографии). Но `delete_own_account()`
--      уносит каскадом и `room_members`, поэтому к моменту уборки
--      `my_room_ids()` пуст, и politика отказывает автору в его же файлах.
--      Комментарий над `deleteAccount()` прямо говорит, почему такой порядок
--      вообще возможен: «storage DELETE policies test nothing but the path
--      prefix against auth.uid()». Для `posts/` и `avatars/` это правда, для
--      `messages/` — нет, и это расхождение никто не заметил.
--   2. **Автор вышел из комнаты и удаляет своё старое сообщение.**
--      `delete_own_room_message()` членства не требует (только авторство),
--      то есть строку он погасит, она вернёт ему пути — а `remove()` по ним
--      получит отказ. Тихий: уборка объектов best-effort по построению.
--
-- В обоих случаях байты оставались сиротами до `reap_orphaned_media()` —
-- сотня в час, не раньше суток. Для чата, куда кладут 100-мегабайтные
-- клипы, это тот же «не тот инструмент», которым комментарий к
-- `create_post_with_media()` объясняет, почему клиент вообще убирает за
-- собой сам.
--
-- ЧТО СТАЛО. Условие членства снято с DELETE — и только с DELETE. SELECT
-- («кому видно») и INSERT («кому можно писать») членство требуют
-- по-прежнему и требовать обязаны: там комната и есть вопрос. Новое право
-- строго уже старого в одном смысле и шире в другом: автор не получает
-- доступа ни к одному чужому объекту, но получает доступ к своим после
-- ухода. Второе не новая возможность, а приведение в соответствие с уже
-- существующей: погасить своё сообщение из покинутой комнаты
-- `delete_own_room_message()` разрешает и сейчас.
-- =====================================================================

drop policy "Authors can delete their own message media" on storage.objects;

-- Третий сегмент пути — это и есть право. Первый и второй остаются в
-- условии как форма пути (иначе политика говорила бы о любом объекте,
-- у которого третья папка совпала с uuid вызывающего), но комнату больше
-- не спрашивают.
create policy "Authors can delete their own message media"
  on storage.objects
  for delete
  to authenticated
  using (((bucket_id = 'media'::text) AND ((storage.foldername(name))[1] = 'messages'::text)
    AND ((storage.foldername(name))[3] = (auth.uid())::text)));


-- =====================================================================
-- Проверки после наката
-- =====================================================================
do $$
declare
  v_using text;
begin
  select pg_get_expr(polqual, polrelid) into v_using
    from pg_policy
   where polrelid = 'storage.objects'::regclass
     and polname = 'Authors can delete their own message media';

  if v_using is null then
    raise exception 'DELETE-политика вложений не пересоздалась';
  end if;
  -- Авторство осталось: без него политика отдавала бы чужие байты.
  if v_using not like '%foldername(name))[3] = (auth.uid())::text%' then
    raise exception 'DELETE-политика вложений потеряла проверку авторства';
  end if;
  -- А членство ушло — ровно то, ради чего миграция.
  if v_using like '%my_room_ids%' then
    raise exception 'DELETE-политика вложений всё ещё требует членства';
  end if;

  -- Соседние две политики не тронуты: обе про комнату, и обе обязаны о ней
  -- спрашивать.
  if (select pg_get_expr(polqual, polrelid) from pg_policy
       where polrelid = 'storage.objects'::regclass
         and polname = 'Message media are viewable by room members')
     not like '%my_room_ids%' then
    raise exception 'SELECT-политика вложений потеряла проверку членства';
  end if;
  if (select pg_get_expr(polwithcheck, polrelid) from pg_policy
       where polrelid = 'storage.objects'::regclass
         and polname = 'Room members can upload message media')
     not like '%my_room_ids%' then
    raise exception 'INSERT-политика вложений потеряла проверку членства';
  end if;

  if (select count(*) from pg_policy where polrelid = 'storage.objects'::regclass
       and polname in ('Message media are viewable by room members',
                       'Room members can upload message media',
                       'Authors can delete their own message media')) <> 3 then
    raise exception 'storage-политики сообщений завелись не полностью';
  end if;
end;
$$;
