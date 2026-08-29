-- =====================================================================
-- connections.method: третье значение для рядов, заведённых вручную.
--
-- 'qr_code' в CHECK'е — задел под будущую фичу (project-brief.md,
-- future-development.md: сканирование QR как второй способ знакомства,
-- в MVP не входит), а не реализованный путь. Единственное место, которое
-- пишет в connections, — activate_invite_link() (см. baseline), и она
-- всегда ставит 'invite_link'. Ни одна живая строка с 'qr_code' не пришла
-- из приложения: все они заведены вручную через Management API для
-- тестовых данных и подписаны так, будто прошли через несуществующий путь.
--
-- Заводим отдельное значение под ручные вставки и переклеиваем на него уже
-- существующие такие строки; 'qr_code' остаётся свободным для реальной
-- фичи, когда она появится.
-- =====================================================================

alter table public.connections drop constraint connections_method_check;
alter table public.connections add constraint connections_method_check
  CHECK ((method = ANY (ARRAY['invite_link'::text, 'qr_code'::text, 'manual'::text])));

update public.connections
   set method = 'manual'
 where method = 'qr_code';
