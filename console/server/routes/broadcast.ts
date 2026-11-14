import { Router } from 'express';
import type { BroadcastResponse, BroadcastTarget } from '../../shared/types.ts';
import { loadDevices } from '../aggregate.ts';
import { fetchAll } from '../db.ts';
import { repoVersion } from '../release.ts';
import { admin } from '../supabase.ts';

export const broadcastRouter = Router();

const UPDATE_KINDS = ['app_update', 'app_update_important'];

/// What to sort a history row by when its build is a string.
///
/// `?` is substituted where the payload had no build, and that was the
/// problem: `Number('?')` is NaN, and a comparator that returns NaN defines no
/// order at all. `sort` takes such an answer as "leave as is", and ONE such
/// row was enough for the whole history table to come out in an
/// implementation-dependent order, silently, because the row itself renders
/// fine. The `?? '?'` default shows that rows without a build were expected;
/// the second half was not updated.
///
/// -1 rather than 0: "build unknown" is the oldest thing there can be, and in
/// a table sorted from newest to oldest it belongs at the end.
function buildOrder(build: string): number {
  const parsed = Number(build);
  return Number.isFinite(parsed) ? parsed : -1;
}

// Repeats the selection in `enqueue_app_update_notifications()` word for word,
// to show the list BEFORE sending. The source of truth is the function
// itself; this is its mirror, and if they diverge the function is right. For
// the same reason the code below shows how many rows the function actually
// created: a divergence becomes visible immediately, not when someone fails
// to get a notification.
//
// Selection: the person has at least one device, the maximum `app_build`
// across all their devices is below the target build (NULL counts as zero,
// "older than anything known"), they have not turned off
// `notify_system_account`, and they have not yet been queued either a regular
// or an insistent notification for THIS build.
async function audience(targetBuild: number) {
  const [devices, users, prefs, outbox] = await Promise.all([
    loadDevices(),
    fetchAll<{ id: string; name: string }>('users', 'id, name'),
    fetchAll<{ user_id: string; notify_system_account: boolean }>(
      'notification_preferences',
      'user_id, notify_system_account',
    ),
    fetchAll<{
      user_id: string;
      kind: string;
      payload: Record<string, unknown>;
    }>('notification_outbox', 'user_id, kind, payload', (q) =>
      q.in('kind', UPDATE_KINDS),
    ),
  ]);

  const nameOf = new Map(users.map((u) => [u.id, u.name]));
  const maxBuild = new Map<string, number>();
  const localeOf = new Map<string, string>();
  for (const d of devices) {
    const seen = maxBuild.get(d.user_id) ?? 0;
    maxBuild.set(d.user_id, Math.max(seen, d.app_build ?? 0));
    localeOf.set(d.user_id, d.locale);
  }

  const optedOut = new Set(
    prefs
      .filter((p) => p.notify_system_account === false)
      .map((p) => p.user_id),
  );
  const alreadyToldAbout = new Set(
    outbox
      .filter((n) => String(n.payload?.build ?? '') === String(targetBuild))
      .map((n) => n.user_id),
  );

  const behind: BroadcastTarget[] = [];
  const skippedOptOut: BroadcastTarget[] = [];
  const skippedAlready: BroadcastTarget[] = [];
  for (const [userId, build] of maxBuild) {
    if (build >= targetBuild) continue;
    const row: BroadcastTarget = {
      userId,
      name: nameOf.get(userId) ?? '—',
      maxBuild: build === 0 ? null : build,
      locale: localeOf.get(userId) ?? '—',
    };
    if (alreadyToldAbout.has(userId)) skippedAlready.push(row);
    else if (optedOut.has(userId)) skippedOptOut.push(row);
    else behind.push(row);
  }

  const sort = (rows: BroadcastTarget[]) =>
    rows.sort((a, b) => (a.maxBuild ?? 0) - (b.maxBuild ?? 0));

  return {
    willReceive: sort(behind),
    skippedAlready: sort(skippedAlready),
    skippedOptOut: sort(skippedOptOut),
    withoutDevices: users.filter((u) => !maxBuild.has(u.id)).length,
    history: [
      ...outbox
        .reduce((map, n) => {
          const build = String(n.payload?.build ?? '?');
          const key = `${build}|${n.kind}`;
          const entry = map.get(key) ?? { build, kind: n.kind, users: 0 };
          entry.users += 1;
          map.set(key, entry);
          return map;
        }, new Map<string, { build: string; kind: string; users: number }>())
        .values(),
    ].sort((a, b) => buildOrder(b.build) - buildOrder(a.build)),
  };
}

broadcastRouter.get('/broadcast', async (req, res, next) => {
  try {
    const repo = await repoVersion();
    const target = Number(req.query.build ?? repo?.build ?? 0);
    if (!Number.isInteger(target) || target <= 0) {
      res
        .status(400)
        .json({ error: 'build должен иметь положительный versionCode' });
      return;
    }
    const body: BroadcastResponse = {
      generatedAt: new Date().toISOString(),
      repoVersion: repo,
      targetBuild: target,
      ...(await audience(target)),
    };
    res.json(body);
  } catch (error) {
    next(error);
  }
});

broadcastRouter.post('/broadcast/app-update', async (req, res, next) => {
  try {
    const build = Number(req.body?.build);
    const version =
      typeof req.body?.version === 'string' ? req.body.version : null;
    const important = req.body?.important === true;
    if (!Number.isInteger(build) || build <= 0) {
      res
        .status(400)
        .json({ error: 'build должен иметь положительный versionCode' });
      return;
    }

    // The function itself is called rather than repeating its logic as an
    // insert: selection, repeat protection and kind choice are its job, and
    // this spot needs no second implementation. The console is only an input
    // form here.
    const { data, error } = await admin.rpc(
      'enqueue_app_update_notifications',
      {
        p_min_build: build,
        p_version: version,
        p_important: important,
      },
    );
    if (error)
      throw new Error(`enqueue_app_update_notifications: ${error.message}`);

    res.json({ ok: true, queued: typeof data === 'number' ? data : 0 });
  } catch (error) {
    next(error);
  }
});
