import { Router } from 'express';
import type {
  ModerationTargetKind,
  ReportMedia,
  ReportRow,
  ReportsResponse,
} from '../../shared/types.ts';
import { admin } from '../supabase.ts';
import { fetchAll, fetchAuthUsers, fetchOnce } from '../db.ts';

export const moderationRouter = Router();

// Таблица и колонка, в которых живёт объект каждого вида. Одно место вместо
// трёх веток в каждом обработчике.
const TARGETS: Record<ModerationTargetKind, { table: string; author: string }> = {
  post: { table: 'posts', author: 'author_id' },
  comment: { table: 'comments', author: 'author_id' },
  room_message: { table: 'room_messages', author: 'author_id' },
};

function isTargetKind(value: unknown): value is ModerationTargetKind {
  return value === 'post' || value === 'comment' || value === 'room_message';
}

// Уведомления модерации настройкой не выключаются — намеренно, по тому же
// правилу, что и заявки в знакомые: они адресованы лично и приходят раз в
// жизни, а «больше никогда не узнаю, что мой пост убрали» — не тот выбор,
// который стоит предлагать. Поэтому `notification_preferences` здесь не
// спрашивается вовсе.
async function enqueue(userId: string, kind: string, note?: string) {
  const trimmed = note?.trim();
  const { error } = await admin.from('notification_outbox').insert({
    user_id: userId,
    kind,
    payload: trimmed ? { note: trimmed } : {},
  });
  if (error) throw new Error(`notification_outbox: ${error.message}`);
}


// Медиа объекта, на который жалуются. Без него решение по картинке принимать
// нечем: снимок текста у такого поста пустой, а весь смысл жалобы — в том,
// что на фотографии.
//
// Ссылки подписанные и живут час: бакет `media` приватный, и делать его
// публичным ради консоли — последнее, что стоит делать. Подписывает сервер,
// потому что service_role живёт только здесь.
async function mediaForTargets(
  posts: string[],
  messages: string[],
): Promise<Map<string, ReportMedia[]>> {
  const raw = new Map<string, { kind: string; path: string; poster: string | null }[]>();

  if (posts.length > 0) {
    const rows = await fetchOnce<{
      post_id: string;
      media_type: string;
      storage_path: string;
      poster_path: string | null;
    }>('post_media', 'post_id, media_type, storage_path, poster_path', (q: any) =>
      q.in('post_id', posts),
    );
    for (const r of rows) {
      const list = raw.get(`post:${r.post_id}`) ?? [];
      list.push({ kind: r.media_type, path: r.storage_path, poster: r.poster_path });
      raw.set(`post:${r.post_id}`, list);
    }
  }

  if (messages.length > 0) {
    const rows = await fetchOnce<{ id: string; media: unknown }>(
      'room_messages',
      'id, media',
      (q: any) => q.in('id', messages),
    );
    for (const r of rows) {
      const items = Array.isArray(r.media) ? r.media : [];
      const list: { kind: string; path: string; poster: string | null }[] = [];
      for (const item of items as Record<string, string>[]) {
        if (!item?.storage_path) continue;
        list.push({
          kind: item.media_type ?? 'image',
          path: item.storage_path,
          poster: item.poster_path || null,
        });
      }
      if (list.length > 0) raw.set(`room_message:${r.id}`, list);
    }
  }

  const paths = [
    ...new Set(
      [...raw.values()].flatMap((items) =>
        items.flatMap((i) => (i.poster ? [i.path, i.poster] : [i.path])),
      ),
    ),
  ];
  const signed = new Map<string, string>();
  if (paths.length > 0) {
    const { data, error } = await admin.storage.from('media').createSignedUrls(paths, 3600);
    if (error) throw new Error(`storage: ${error.message}`);
    for (const entry of data ?? []) {
      if (entry.signedUrl && entry.path) signed.set(entry.path, entry.signedUrl);
    }
  }

  const out = new Map<string, ReportMedia[]>();
  for (const [key, items] of raw) {
    out.set(
      key,
      items.map((i) => ({
        kind: i.kind,
        path: i.path,
        url: signed.get(i.path) ?? null,
        posterUrl: i.poster ? signed.get(i.poster) ?? null : null,
      })),
    );
  }
  return out;
}

moderationRouter.get('/reports', async (req, res, next) => {
  try {
    const onlyOpen = req.query.status !== 'all';
    // Читается ВСЯ таблица независимо от фильтра: история жалобщика считается
    // по всем его жалобам, а не по тем, что сейчас на экране. Фильтр
    // применяется ниже, к выдаче.
    const rows = await fetchAll<{
      id: string;
      reporter_id: string;
      target_kind: string;
      target_id: string;
      reason: string;
      note: string | null;
      target_author_id: string | null;
      target_snapshot: string | null;
      created_at: string;
      status: string;
      resolution: string | null;
      resolved_at: string | null;
    }>('content_reports', '*');

    const [users, auth] = await Promise.all([
      fetchAll<{ id: string; name: string }>('users', 'id, name'),
      fetchAuthUsers(),
    ]);
    const nameOf = new Map(users.map((u) => [u.id, u.name]));

    // Жив ли ещё объект и не скрыт ли он уже — иначе в очереди не видно
    // разницы между «надо разобрать» и «уже разобрано, жалоба осталась».
    const state = new Map<string, { exists: boolean; hidden: boolean }>();
    for (const kind of ['post', 'comment', 'room_message'] as const) {
      const ids = [...new Set(rows.filter((r) => r.target_kind === kind).map((r) => r.target_id))];
      if (ids.length === 0) continue;
      const found = await fetchOnce<{ id: string; hidden_at: string | null }>(
        TARGETS[kind].table,
        'id, hidden_at',
        (q: any) => q.in('id', ids),
      );
      const byId = new Map(found.map((f) => [f.id, f.hidden_at]));
      for (const id of ids) {
        state.set(`${kind}:${id}`, {
          exists: byId.has(id),
          hidden: byId.get(id) != null,
        });
      }
    }

    const media = await mediaForTargets(
      [...new Set(rows.filter((r) => r.target_kind === 'post').map((r) => r.target_id))],
      [...new Set(rows.filter((r) => r.target_kind === 'room_message').map((r) => r.target_id))],
    );

    // Сколько жалоб подал сам жалобщик и сколько из них отклонили. Сигнал не
    // про автора, а про того, кто жалуется: пятая отклонённая жалоба подряд
    // говорит о человеке больше, чем любая из них по отдельности.
    const byReporter = new Map<string, { total: number; rejected: number }>();
    for (const r of rows) {
      const stat = byReporter.get(r.reporter_id) ?? { total: 0, rejected: 0 };
      stat.total += 1;
      if (r.status === 'rejected') stat.rejected += 1;
      byReporter.set(r.reporter_id, stat);
    }

    // Сколько всего жалоб на этот же объект — главный сигнал очереди: одна
    // жалоба и семь жалоб на одно и то же читаются по-разному.
    const perTarget = new Map<string, number>();
    for (const r of rows) {
      const key = `${r.target_kind}:${r.target_id}`;
      perTarget.set(key, (perTarget.get(key) ?? 0) + 1);
    }

    const reports: ReportRow[] = rows
      .map((r) => {
        const key = `${r.target_kind}:${r.target_id}`;
        const known = state.get(key);
        return {
          id: r.id,
          reporterId: r.reporter_id,
          reporterName: nameOf.get(r.reporter_id) ?? '—',
          targetKind: r.target_kind,
          targetId: r.target_id,
          targetAuthorId: r.target_author_id,
          targetAuthorName: r.target_author_id
            ? nameOf.get(r.target_author_id) ?? '—'
            : null,
          targetAuthorBanned: r.target_author_id
            ? Boolean(auth.get(r.target_author_id)?.bannedUntil)
            : false,
          targetSnapshot: r.target_snapshot,
          media: media.get(key) ?? [],
          targetExists: r.target_kind === 'user' ? true : known?.exists ?? false,
          targetHidden: known?.hidden ?? false,
          reportsOnTarget: perTarget.get(key) ?? 1,
          reporterTotal: byReporter.get(r.reporter_id)?.total ?? 1,
          reporterRejected: byReporter.get(r.reporter_id)?.rejected ?? 0,
          reason: r.reason,
          note: r.note,
          createdAt: r.created_at,
          status: r.status,
          resolution: r.resolution,
          resolvedAt: r.resolved_at,
        };
      })
      .filter((r) => (onlyOpen ? r.status === 'open' : true))
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt));

    const body: ReportsResponse = {
      generatedAt: new Date().toISOString(),
      open: rows.filter((r) => r.status === 'open').length,
      reports,
    };
    res.json(body);
  } catch (error) {
    next(error);
  }
});

moderationRouter.post('/moderation/content', async (req, res, next) => {
  try {
    const { kind, targetId, action, notifyAuthor, note } = req.body ?? {};
    if (!isTargetKind(kind) || typeof targetId !== 'string') {
      res.status(400).json({ error: 'Нужны kind и targetId' });
      return;
    }
    const { table, author } = TARGETS[kind];

    const existing = await fetchOnce<Record<string, unknown>>(table, `id, ${author}`, (q: any) =>
      q.eq('id', targetId),
    );
    if (existing.length === 0) {
      res.status(404).json({ error: 'Объект уже не существует' });
      return;
    }
    const authorId = existing[0][author] as string;

    if (action === 'hide' || action === 'unhide') {
      const { error } = await admin
        .from(table)
        .update({ hidden_at: action === 'hide' ? new Date().toISOString() : null })
        .eq('id', targetId);
      if (error) throw new Error(`${table}: ${error.message}`);
    } else if (action === 'delete') {
      if (kind === 'post') {
        // Пост сносится строкой: комментарии и `post_media` уходят по
        // внешним ключам, а объекты в бакете становятся ничьими и их
        // выносит `reap-orphaned-media` — тот же путь, что и у поста,
        // удалённого самим автором.
        const { error } = await admin.from('posts').delete().eq('id', targetId);
        if (error) throw new Error(`posts: ${error.message}`);
      } else {
        // Комментарий и сообщение — заглушкой, как это делает само
        // приложение (`delete_own_comment`, `delete_own_room_message`):
        // строка нужна, чтобы не оборвать ветку ответов на неё. Своей,
        // второй семантики удаления у модерации нет намеренно.
        const patch: Record<string, unknown> = {
          deleted_at: new Date().toISOString(),
          text: '',
        };
        if (kind === 'room_message') patch.media = [];
        const { error } = await admin.from(table).update(patch).eq('id', targetId);
        if (error) throw new Error(`${table}: ${error.message}`);
      }
    } else {
      res.status(400).json({ error: 'action: hide, unhide или delete' });
      return;
    }

    if (notifyAuthor && action !== 'unhide') {
      await enqueue(authorId, 'moderation_notice', note);
    }
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

moderationRouter.post('/moderation/ban', async (req, res, next) => {
  try {
    const { userId, mode, days, notify, note } = req.body ?? {};
    if (typeof userId !== 'string') {
      res.status(400).json({ error: 'Нужен userId' });
      return;
    }

    if (mode === 'write' || mode === 'none') {
      const until =
        mode === 'none'
          ? null
          : new Date(Date.now() + Number(days ?? 7) * 864e5).toISOString();
      const { error } = await admin
        .from('users')
        .update({ write_banned_until: until })
        .eq('id', userId);
      if (error) throw new Error(`users: ${error.message}`);
      // Снятие запрета писать снимает и бан входа: иначе «none» означало бы
      // разное в зависимости от того, чем банили, а из консоли это не видно.
      if (mode === 'none') {
        const { error: authError } = await admin.auth.admin.updateUserById(userId, {
          ban_duration: 'none',
        });
        if (authError) throw new Error(`auth: ${authError.message}`);
      }
    } else if (mode === 'auth') {
      // Бан входа живёт в GoTrue, не в нашей схеме: своей копии этого факта
      // заводить не стоит — разошлась бы с настоящей при первом же снятии
      // через дашборд.
      const hours = Math.max(1, Math.round(Number(days ?? 3650) * 24));
      const { error } = await admin.auth.admin.updateUserById(userId, {
        ban_duration: `${hours}h`,
      });
      if (error) throw new Error(`auth: ${error.message}`);
    } else {
      res.status(400).json({ error: 'mode: write, auth или none' });
      return;
    }

    if (notify && mode !== 'none') {
      await enqueue(userId, 'moderation_notice', note);
    }
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

// Какие готовые виды осмысленно послать ОДНОМУ человеку руками.
//
// Список закрыт намеренно и короче, чем CHECK таблицы: остальные виды —
// событийные. Послать «у вас новый комментарий» там, где комментария не
// было, значит соврать человеку голосом приложения, и никакой удобный UI
// этого не оправдывает. `report_resolved`/`report_rejected` сюда тоже не
// входят: их текст описывает исход разбора жалобы и врозь с ним смысла не
// имеет — они уходят из очереди жалоб.
const MANUAL_KINDS: Record<string, { needsBuild: boolean; title: string }> = {
  app_update: { needsBuild: true, title: 'вышла новая версия' },
  app_update_important: { needsBuild: true, title: 'важное обновление' },
  moderation_notice: { needsBuild: false, title: 'сообщение модерации' },
};

// Адресная отправка одному человеку. Повторяет две проверки, которые для
// массовой рассылки делает `enqueue_app_update_notifications()`: уважает
// `notify_system_account` и не кладёт второе уведомление про ту же сборку.
// Для `moderation_notice` ни то, ни другое не применяется — это личное
// сообщение о его же материале, а не рассылка, и настройкой оно не
// выключается (то же правило, что у заявок в знакомые).
moderationRouter.post('/users/:id/notify', async (req, res, next) => {
  try {
    const kind = String(req.body?.kind ?? '');
    const spec = MANUAL_KINDS[kind];
    if (!spec) {
      res.status(400).json({
        error: `kind: ${Object.keys(MANUAL_KINDS).join(', ')}`,
      });
      return;
    }

    const user = await fetchOnce<{ id: string }>('users', 'id', (q: any) =>
      q.eq('id', req.params.id),
    );
    if (user.length === 0) {
      res.status(404).json({ error: 'Пользователь не найден' });
      return;
    }

    if (spec.needsBuild) {
      const build = Number(req.body?.build);
      if (!Number.isInteger(build) || build <= 0) {
        res.status(400).json({ error: 'Для этого вида нужен build — положительный versionCode' });
        return;
      }

      const prefs = await fetchOnce<{ notify_system_account: boolean }>(
        'notification_preferences',
        'notify_system_account',
        (q: any) => q.eq('user_id', req.params.id),
      );
      if (prefs[0]?.notify_system_account === false) {
        res.status(409).json({ error: 'Человек выключил уведомления системного аккаунта' });
        return;
      }

      const already = await fetchOnce<{ id: string; payload: Record<string, unknown> }>(
        'notification_outbox',
        'id, payload',
        (q: any) =>
          q.eq('user_id', req.params.id).in('kind', ['app_update', 'app_update_important']),
      );
      if (already.some((n) => String(n.payload?.build ?? '') === String(build))) {
        res.status(409).json({ error: 'Про эту сборку ему уже отправляли' });
        return;
      }

      const { error } = await admin.from('notification_outbox').insert({
        user_id: req.params.id,
        kind,
        payload: { build, version: req.body?.version ?? null },
      });
      if (error) throw new Error(`notification_outbox: ${error.message}`);
    } else {
      await enqueue(req.params.id, kind, typeof req.body?.note === 'string' ? req.body.note : undefined);
    }

    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

moderationRouter.post('/reports/:id/resolve', async (req, res, next) => {
  try {
    const { status, resolution, notifyReporter, note } = req.body ?? {};
    if (status !== 'resolved' && status !== 'rejected') {
      res.status(400).json({ error: 'status: resolved или rejected' });
      return;
    }
    const rows = await fetchOnce<{ reporter_id: string }>(
      'content_reports',
      'reporter_id',
      (q: any) => q.eq('id', req.params.id),
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Жалоба не найдена' });
      return;
    }

    const { error } = await admin
      .from('content_reports')
      .update({
        status,
        resolution: typeof resolution === 'string' && resolution.trim() ? resolution.trim() : null,
        resolved_at: new Date().toISOString(),
      })
      .eq('id', req.params.id);
    if (error) throw new Error(`content_reports: ${error.message}`);

    if (notifyReporter) {
      // Вид зависит от исхода: «меры приняты» и «нарушения не нашли» — разные
      // сообщения, и слать одно на оба означало бы, что два статуса разбора
      // ни на что не влияют (20260913110000).
      await enqueue(
        rows[0].reporter_id,
        status === 'resolved' ? 'report_resolved' : 'report_rejected',
        note,
      );
    }
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});
