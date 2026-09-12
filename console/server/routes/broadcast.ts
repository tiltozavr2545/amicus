import { Router } from 'express';
import type { BroadcastResponse, BroadcastTarget } from '../../shared/types.ts';
import { admin } from '../supabase.ts';
import { fetchAll } from '../db.ts';
import { loadDevices } from '../aggregate.ts';
import { repoVersion } from '../release.ts';

export const broadcastRouter = Router();

const UPDATE_KINDS = ['app_update', 'app_update_important'];

// Повторяет отбор `enqueue_app_update_notifications()` слово в слово, чтобы
// показать список ДО отправки. Источник истины — сама функция; это её
// зеркало, и если они разойдутся, права будет функция. Поэтому же ниже
// показывается, сколько строк она реально завела: расхождение станет видно
// сразу, а не когда кто-то не получит уведомление.
//
// Отбор: у человека есть хоть одно устройство, максимум `app_build` по всем
// его устройствам меньше целевой сборки (NULL считается нулём — «старее
// всего известного»), он не выключил `notify_system_account`, и про ЭТУ
// сборку ему ещё не клали ни обычное уведомление, ни настойчивое.
async function audience(targetBuild: number) {
  const [devices, users, prefs, outbox] = await Promise.all([
    loadDevices(),
    fetchAll<{ id: string; name: string }>('users', 'id, name'),
    fetchAll<{ user_id: string; notify_system_account: boolean }>(
      'notification_preferences',
      'user_id, notify_system_account',
    ),
    fetchAll<{ user_id: string; kind: string; payload: Record<string, unknown> }>(
      'notification_outbox',
      'user_id, kind, payload',
      (q: any) => q.in('kind', UPDATE_KINDS),
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
    prefs.filter((p) => p.notify_system_account === false).map((p) => p.user_id),
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
    history: [...
      outbox
        .reduce((map, n) => {
          const build = String(n.payload?.build ?? '?');
          const key = `${build}|${n.kind}`;
          const entry = map.get(key) ?? { build, kind: n.kind, users: 0 };
          entry.users += 1;
          map.set(key, entry);
          return map;
        }, new Map<string, { build: string; kind: string; users: number }>())
        .values(),
    ].sort((a, b) => Number(b.build) - Number(a.build)),
  };
}

broadcastRouter.get('/broadcast', async (req, res, next) => {
  try {
    const repo = await repoVersion();
    const target = Number(req.query.build ?? repo?.build ?? 0);
    if (!Number.isInteger(target) || target <= 0) {
      res.status(400).json({ error: 'build должен быть положительным versionCode' });
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
    const version = typeof req.body?.version === 'string' ? req.body.version : null;
    const important = req.body?.important === true;
    if (!Number.isInteger(build) || build <= 0) {
      res.status(400).json({ error: 'build должен быть положительным versionCode' });
      return;
    }

    // Вызывается сама функция, а не повторяется её логика вставкой: отбор,
    // защита от повтора и выбор вида — её дело, и второй реализации этому
    // месту не нужно. Консоль здесь только форма ввода.
    const { data, error } = await admin.rpc('enqueue_app_update_notifications', {
      p_min_build: build,
      p_version: version,
      p_important: important,
    });
    if (error) throw new Error(`enqueue_app_update_notifications: ${error.message}`);

    res.json({ ok: true, queued: typeof data === 'number' ? data : 0 });
  } catch (error) {
    next(error);
  }
});
