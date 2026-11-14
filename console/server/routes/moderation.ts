import { Router } from 'express';
import type {
  ModerationTargetKind,
  ReportMedia,
  ReportRow,
  ReportsResponse,
} from '../../shared/types.ts';
import {
  authBanDuration,
  parseBanDays,
  writeBanUntil,
} from '../ban_duration.ts';
import { fetchAll, fetchAuthUsers, fetchOnce } from '../db.ts';
import { admin } from '../supabase.ts';
import { isUuid, uuidParam } from '../uuid.ts';

export const moderationRouter = Router();
moderationRouter.param('id', uuidParam);

// The table and column where each kind of object lives. One place instead of
// three branches in every handler.
const TARGETS: Record<ModerationTargetKind, { table: string; author: string }> =
  {
    post: { table: 'posts', author: 'author_id' },
    comment: { table: 'comments', author: 'author_id' },
    room_message: { table: 'room_messages', author: 'author_id' },
  };

function isTargetKind(value: unknown): value is ModerationTargetKind {
  return value === 'post' || value === 'comment' || value === 'room_message';
}

// Moderation notifications can't be turned off in settings — deliberately, by
// the same rule as connection requests: they're addressed personally and come
// once in a lifetime, and "I'll never find out my post was removed" isn't a
// choice worth offering. So `notification_preferences` isn't consulted here
// at all.
async function enqueue(userId: string, kind: string, note?: string) {
  const trimmed = note?.trim();
  const { error } = await admin.from('notification_outbox').insert({
    user_id: userId,
    kind,
    payload: trimmed ? { note: trimmed } : {},
  });
  if (error) throw new Error(`notification_outbox: ${error.message}`);
}

// Media of the reported object. Without it there's nothing to base a decision
// about a picture on: the text snapshot of such a post is empty, and the whole
// point of the report is what's in the photo.
//
// The links are signed and live for an hour: the `media` bucket is private,
// and making it public for the console's sake is the last thing to do. The
// server signs them, because service_role lives only here.
async function mediaForTargets(
  posts: string[],
  messages: string[],
): Promise<Map<string, ReportMedia[]>> {
  const raw = new Map<
    string,
    { kind: string; path: string; poster: string | null }[]
  >();

  if (posts.length > 0) {
    const rows = await fetchOnce<{
      post_id: string;
      media_type: string;
      storage_path: string;
      poster_path: string | null;
    }>('post_media', 'post_id, media_type, storage_path, poster_path', (q) =>
      q.in('post_id', posts),
    );
    for (const r of rows) {
      const list = raw.get(`post:${r.post_id}`) ?? [];
      list.push({
        kind: r.media_type,
        path: r.storage_path,
        poster: r.poster_path,
      });
      raw.set(`post:${r.post_id}`, list);
    }
  }

  if (messages.length > 0) {
    const rows = await fetchOnce<{ id: string; media: unknown }>(
      'room_messages',
      'id, media',
      (q) => q.in('id', messages),
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
    const { data, error } = await admin.storage
      .from('media')
      .createSignedUrls(paths, 3600);
    if (error) throw new Error(`storage: ${error.message}`);
    for (const entry of data ?? []) {
      if (entry.signedUrl && entry.path)
        signed.set(entry.path, entry.signedUrl);
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
        posterUrl: i.poster ? (signed.get(i.poster) ?? null) : null,
      })),
    );
  }
  return out;
}

moderationRouter.get('/reports', async (req, res, next) => {
  try {
    const onlyOpen = req.query.status !== 'all';
    // The WHOLE table is read regardless of the filter: a reporter's history
    // is counted over all their reports, not just the ones on screen now. The
    // filter is applied below, to the output.
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

    // Whether the object still exists and whether it's already hidden —
    // otherwise the queue can't tell "needs handling" from "already handled,
    // the report just remains".
    const state = new Map<string, { exists: boolean; hidden: boolean }>();
    for (const kind of ['post', 'comment', 'room_message'] as const) {
      const ids = [
        ...new Set(
          rows.filter((r) => r.target_kind === kind).map((r) => r.target_id),
        ),
      ];
      if (ids.length === 0) continue;
      const found = await fetchOnce<{ id: string; hidden_at: string | null }>(
        TARGETS[kind].table,
        'id, hidden_at',
        (q) => q.in('id', ids),
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
      [
        ...new Set(
          rows.filter((r) => r.target_kind === 'post').map((r) => r.target_id),
        ),
      ],
      [
        ...new Set(
          rows
            .filter((r) => r.target_kind === 'room_message')
            .map((r) => r.target_id),
        ),
      ],
    );

    // How many reports the reporter filed and how many of them were rejected.
    // The signal is about the reporter, not the author: a fifth rejected
    // report in a row says more about a person than any one of them alone.
    const byReporter = new Map<string, { total: number; rejected: number }>();
    for (const r of rows) {
      const stat = byReporter.get(r.reporter_id) ?? { total: 0, rejected: 0 };
      stat.total += 1;
      if (r.status === 'rejected') stat.rejected += 1;
      byReporter.set(r.reporter_id, stat);
    }

    // Total reports on the same object — the queue's main signal: one report
    // and seven reports on the same thing read differently.
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
            ? (nameOf.get(r.target_author_id) ?? '—')
            : null,
          targetAuthorBanned: r.target_author_id
            ? Boolean(auth.get(r.target_author_id)?.bannedUntil)
            : false,
          targetSnapshot: r.target_snapshot,
          media: media.get(key) ?? [],
          targetExists:
            r.target_kind === 'user' ? true : (known?.exists ?? false),
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
    if (!isTargetKind(kind) || !isUuid(targetId)) {
      res.status(400).json({ error: 'Нужны kind и targetId (uuid)' });
      return;
    }
    const { table, author } = TARGETS[kind];

    const existing = await fetchOnce<Record<string, unknown>>(
      table,
      `id, ${author}`,
      (q) => q.eq('id', targetId),
    );
    if (existing.length === 0) {
      res.status(404).json({ error: 'Объект уже не существует' });
      return;
    }
    const authorId = existing[0][author] as string;

    if (action === 'hide' || action === 'unhide') {
      const { error } = await admin
        .from(table)
        .update({
          hidden_at: action === 'hide' ? new Date().toISOString() : null,
        })
        .eq('id', targetId);
      if (error) throw new Error(`${table}: ${error.message}`);
    } else if (action === 'delete') {
      if (kind === 'post') {
        // A post is deleted as a row: comments and `post_media` go via
        // foreign keys, and the bucket objects become orphaned and get
        // cleared by `reap-orphaned-media` — the same path as for a post
        // deleted by its own author.
        const { error } = await admin.from('posts').delete().eq('id', targetId);
        if (error) throw new Error(`posts: ${error.message}`);
      } else {
        // A comment or message becomes a tombstone, as the app itself does
        // (`delete_own_comment`, `delete_own_room_message`): the row is
        // needed so the reply thread under it isn't cut off. Moderation
        // deliberately has no second deletion semantics of its own.
        const patch: Record<string, unknown> = {
          deleted_at: new Date().toISOString(),
          text: '',
        };
        if (kind === 'room_message') patch.media = [];
        const { error } = await admin
          .from(table)
          .update(patch)
          .eq('id', targetId);
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
    if (!isUuid(userId)) {
      res.status(400).json({ error: 'Нужен userId (uuid)' });
      return;
    }

    // Parsing and bounds live in `ban_duration.ts`, along with why they exist
    // there at all.
    const parsed = parseBanDays(days);
    if (!parsed.ok) {
      res.status(400).json({ error: parsed.error });
      return;
    }

    if (mode === 'write' || mode === 'none') {
      // The write ban lives in `user_moderation`, not `users` (IMM-541):
      // the client reads `users` whole, and the column leaked from there. A
      // row exists only for those who were banned, so a ban is an upsert
      // and lifting it a plain UPDATE: no row — nothing to lift, and no
      // point creating one just for a NULL.
      const { error } =
        mode === 'none'
          ? await admin
              .from('user_moderation')
              .update({ write_banned_until: null })
              .eq('user_id', userId)
          : await admin.from('user_moderation').upsert({
              user_id: userId,
              write_banned_until: writeBanUntil(parsed.days, Date.now()),
            });
      if (error) throw new Error(`user_moderation: ${error.message}`);
      // Lifting the write ban also lifts the sign-in ban: otherwise "none"
      // would mean different things depending on how the user was banned,
      // and that isn't visible from the console.
      if (mode === 'none') {
        const { error: authError } = await admin.auth.admin.updateUserById(
          userId,
          {
            ban_duration: 'none',
          },
        );
        if (authError) throw new Error(`auth: ${authError.message}`);
      }
    } else if (mode === 'auth') {
      // The sign-in ban lives in GoTrue, not in our schema: keeping our own
      // copy of that fact isn't worth it — it would drift from the real one
      // the first time the ban is lifted via the dashboard.
      const { error } = await admin.auth.admin.updateUserById(userId, {
        ban_duration: authBanDuration(parsed.days),
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

// Which predefined kinds make sense to send to ONE person by hand.
//
// The list is deliberately closed and shorter than the table's CHECK: the
// other kinds are event-driven. Sending "you have a new comment" where there
// was no comment means lying to a person in the app's voice, and no
// convenient UI justifies that. `report_resolved`/`report_rejected` aren't
// included either: their text describes the outcome of a report review and
// makes no sense apart from it — they're sent from the reports queue.
const MANUAL_KINDS: Record<string, { needsBuild: boolean; title: string }> = {
  app_update: { needsBuild: true, title: 'вышла новая версия' },
  app_update_important: { needsBuild: true, title: 'важное обновление' },
  moderation_notice: { needsBuild: false, title: 'сообщение модерации' },
};

// A targeted send to one person. Repeats the two checks that
// `enqueue_app_update_notifications()` does for a mass broadcast: respects
// `notify_system_account` and doesn't queue a second notification about the
// same build. Neither applies to `moderation_notice` — it's a personal
// message about the person's own content, not a broadcast, and it can't be
// turned off in settings (the same rule as for connection requests).
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

    const user = await fetchOnce<{ id: string }>('users', 'id', (q) =>
      q.eq('id', req.params.id),
    );
    if (user.length === 0) {
      res.status(404).json({ error: 'Пользователь не найден' });
      return;
    }

    if (spec.needsBuild) {
      const build = Number(req.body?.build);
      if (!Number.isInteger(build) || build <= 0) {
        res.status(400).json({
          error: 'Для этого вида нужен build — положительный versionCode',
        });
        return;
      }

      const prefs = await fetchOnce<{ notify_system_account: boolean }>(
        'notification_preferences',
        'notify_system_account',
        (q) => q.eq('user_id', req.params.id),
      );
      if (prefs[0]?.notify_system_account === false) {
        res
          .status(409)
          .json({ error: 'Человек выключил уведомления системного аккаунта' });
        return;
      }

      const already = await fetchOnce<{
        id: string;
        payload: Record<string, unknown>;
      }>('notification_outbox', 'id, payload', (q) =>
        q
          .eq('user_id', req.params.id)
          .in('kind', ['app_update', 'app_update_important']),
      );
      if (
        already.some((n) => String(n.payload?.build ?? '') === String(build))
      ) {
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
      await enqueue(
        req.params.id,
        kind,
        typeof req.body?.note === 'string' ? req.body.note : undefined,
      );
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
      (q) => q.eq('id', req.params.id),
    );
    if (rows.length === 0) {
      res.status(404).json({ error: 'Жалоба не найдена' });
      return;
    }

    const { error } = await admin
      .from('content_reports')
      .update({
        status,
        resolution:
          typeof resolution === 'string' && resolution.trim()
            ? resolution.trim()
            : null,
        resolved_at: new Date().toISOString(),
      })
      .eq('id', req.params.id);
    if (error) throw new Error(`content_reports: ${error.message}`);

    if (notifyReporter) {
      // The kind depends on the outcome: "action taken" and "no violation
      // found" are different messages, and sending one for both would mean
      // the two review statuses affect nothing (20260913110000).
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
