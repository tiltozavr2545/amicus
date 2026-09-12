import { Router } from 'express';
import type { OverviewResponse, VersionRow } from '../../shared/types.ts';
import { countOf, fetchAll } from '../db.ts';
import { groupCount, loadDevices, series } from '../aggregate.ts';
import { repoVersion } from '../release.ts';

export const overviewRouter = Router();

overviewRouter.get('/overview', async (_req, res, next) => {
  try {
    const since7d = new Date(Date.now() - 7 * 864e5).toISOString();
    const since24h = new Date(Date.now() - 864e5).toISOString();

    const [users, activity, devices, posts, outbox7d, prefs, pushStatus] =
      await Promise.all([
      fetchAll<{ id: string; created_at: string }>('users', 'id, created_at'),
      fetchAll<{ user_id: string; last_active_at: string }>(
        'user_activity',
        'user_id, last_active_at',
      ),
      loadDevices(),
      fetchAll<{ id: string; author_id: string; created_at: string }>(
        'posts',
        'id, author_id, created_at',
      ),
      fetchAll<{ kind: string; created_at: string; sent_at: string | null }>(
        'notification_outbox',
        'kind, created_at, sent_at',
        (q) => q.gte('created_at', since7d),
      ),
      fetchAll<Record<string, unknown>>('notification_preferences', '*'),
      fetchAll<{ user_id: string; status: string }>(
        'push_registration_status',
        'user_id, status',
      ),
    ]);

    const [comments, reactions, connections, rooms, roomMessages, pending, repo] =
      await Promise.all([
        countOf('comments'),
        countOf('reactions'),
        countOf('connections'),
        countOf('rooms'),
        countOf('room_messages'),
        countOf('notification_outbox', (q: any) => q.is('sent_at', null)),
        repoVersion(),
      ]);

    // Активность: «был в приложении» — это user_activity, которую пишет сам
    // клиент при запуске. Человек без строки не заходил ни разу с тех пор,
    // как таблица появилась.
    const now = Date.now();
    const lastActive = new Map(activity.map((a) => [a.user_id, a.last_active_at]));
    const within = (iso: string | undefined, days: number) =>
      iso !== undefined && now - Date.parse(iso) <= days * 864e5;
    const dau = users.filter((u) => within(lastActive.get(u.id), 1)).length;
    const wau = users.filter((u) => within(lastActive.get(u.id), 7)).length;
    const mau = users.filter((u) => within(lastActive.get(u.id), 30)).length;

    // Версия — свойство УСТАНОВКИ, не человека: телефон и планшет одного
    // пользователя бывают на разных сборках (docs/data-model.md). Поэтому
    // таблица версий считает и установки, и людей, и «отставшим» считается
    // тот, у кого МАКСИМУМ build по всем устройствам ниже целевого — ровно
    // как в enqueue_app_update_notifications().
    const installsByVersion = new Map<string, VersionRow>();
    const usersByVersion = new Map<string, Set<string>>();
    for (const d of devices) {
      const key = `${d.app_version ?? '—'}+${d.app_build ?? '—'}`;
      const row = installsByVersion.get(key) ?? {
        version: d.app_version,
        build: d.app_build,
        installs: 0,
        users: 0,
      };
      row.installs += 1;
      installsByVersion.set(key, row);
      const set = usersByVersion.get(key) ?? new Set<string>();
      set.add(d.user_id);
      usersByVersion.set(key, set);
    }
    for (const [key, row] of installsByVersion) {
      row.users = usersByVersion.get(key)?.size ?? 0;
    }
    const versions = [...installsByVersion.values()].sort(
      (a, b) => (b.build ?? -1) - (a.build ?? -1),
    );

    // NULL в app_build значит «старее всего известного» (docs/data-model.md),
    // поэтому max(NULL, 5) — это 5, а не NULL.
    const maxBuildByUser = new Map<string, number | null>();
    for (const d of devices) {
      const seen = maxBuildByUser.get(d.user_id);
      if (seen === undefined || seen === null) {
        maxBuildByUser.set(d.user_id, d.app_build);
      } else if (d.app_build !== null && d.app_build > seen) {
        maxBuildByUser.set(d.user_id, d.app_build);
      }
    }
    const latestBuild = devices.reduce<number | null>(
      (max, d) => (d.app_build !== null && (max === null || d.app_build > max) ? d.app_build : max),
      null,
    );
    let usersOnLatest = 0;
    let usersBehind = 0;
    let usersUnknownBuild = 0;
    for (const [, build] of maxBuildByUser) {
      if (build === null) usersUnknownBuild += 1;
      else if (latestBuild !== null && build >= latestBuild) usersOnLatest += 1;
      else usersBehind += 1;
    }
    // «Устройств нет» и «устройство есть, а версию не сообщило» — разные
    // вещи: до первого пуш не дойдёт вовсе, второй просто считается самым
    // старым из известных. Для выбора аудитории это разные списки.
    const usersWithoutDevices = users.length - maxBuildByUser.size;

    // Платформа — свойство установки, как и версия; людей считаем отдельно,
    // потому что один человек законно сидит и с iPhone, и с Android-планшета.
    const usersByPlatform = new Map<string, Set<string>>();
    for (const d of devices) {
      const key = d.platform ?? 'не сообщена';
      const set = usersByPlatform.get(key) ?? new Set<string>();
      set.add(d.user_id);
      usersByPlatform.set(key, set);
    }
    const platforms = [...groupCount(devices, (d) => d.platform ?? 'не сообщена')]
      .map(([platform, installs]) => ({
        platform,
        installs,
        users: usersByPlatform.get(platform)?.size ?? 0,
      }))
      .sort((a, b) => b.installs - a.installs);

    // Возраст токена = сколько устройство не выходило на связь: `updated_at`
    // переписывается при каждом запуске приложения, и пришпиливает его
    // сервер (`pin_device_token_timestamps()`), так что клиент его не
    // подделает. Смотреть сюда стоит с одним вопросом: не накопилось ли
    // мёртвых строк у тех, кому никогда ничего не шлют, — прунинг по
    // UNREGISTERED в send-push срабатывает только на отправке.
    const usersByAge = new Map<string, Set<string>>();
    const ageOf = (iso: string) => {
      const days = (Date.now() - Date.parse(iso)) / 864e5;
      if (days < 7) return 'до недели';
      if (days < 30) return '7–29 дней';
      if (days < 90) return '30–89 дней';
      if (days < 180) return '90–179 дней';
      if (days < 270) return '180–269 дней';
      return '270+ дней';
    };
    for (const d of devices) {
      const key = ageOf(d.updated_at);
      const set = usersByAge.get(key) ?? new Set<string>();
      set.add(d.user_id);
      usersByAge.set(key, set);
    }
    const ageOrder = [
      'до недели',
      '7–29 дней',
      '30–89 дней',
      '90–179 дней',
      '180–269 дней',
      '270+ дней',
    ];
    const tokenAges = [...groupCount(devices, (d) => ageOf(d.updated_at))]
      .map(([bucket, tokens]) => ({
        bucket,
        tokens,
        users: usersByAge.get(bucket)?.size ?? 0,
      }))
      .sort((a, b) => ageOrder.indexOf(a.bucket) - ageOrder.indexOf(b.bucket));

    // Почему до человека не доходит пуш. Прежде на это отвечал только
    // счётчик «без устройств», который валил в кучу отказ в разрешении, сбой
    // регистрации и «просто не открывал приложение с тех пор, как версия
    // научилась это сообщать».
    const STATE_TITLES: Record<string, string> = {
      granted: 'разрешил, токен есть',
      denied: 'отказал в разрешении',
      no_token: 'разрешил, но токен не выдан',
      error: 'регистрация падает с ошибкой',
    };
    const withTokens = new Set(devices.map((d) => d.user_id));
    const statusOf = new Map(pushStatus.map((r) => [r.user_id, r.status]));
    const reach = new Map<string, number>();
    for (const u of users) {
      const status = statusOf.get(u.id);
      let state: string;
      if (status && status !== 'granted') state = STATE_TITLES[status] ?? status;
      else if (withTokens.has(u.id)) state = STATE_TITLES.granted;
      else if (status === 'granted') state = 'токен был и пропал';
      else state = 'не сообщал — старая версия';
      reach.set(state, (reach.get(state) ?? 0) + 1);
    }
    const pushReachability = [...reach]
      .map(([state, count]) => ({ state, users: count }))
      .sort((a, b) => b.users - a.users);

    const locales = [...groupCount(devices, (d) => d.locale)]
      .map(([locale, installs]) => ({ locale, installs }))
      .sort((a, b) => b.installs - a.installs);

    // Отсутствие строки в notification_preferences = всё включено, поэтому
    // выключенным считается только явный false (весь сервер читает эти
    // флаги через coalesce(..., true)).
    const settingNames = new Set<string>();
    for (const row of prefs) {
      for (const [k, v] of Object.entries(row)) {
        if (k !== 'user_id' && typeof v === 'boolean') settingNames.add(k);
      }
    }
    const optOuts = [...settingNames]
      .map((setting) => ({
        setting,
        users: prefs.filter((row) => row[setting] === false).length,
      }))
      .sort((a, b) => b.users - a.users);

    const body: OverviewResponse = {
      generatedAt: new Date().toISOString(),
      totals: {
        users: users.length,
        posts: posts.length,
        comments,
        reactions,
        connections,
        rooms,
        roomMessages,
        devices: devices.length,
      },
      activity: { dau, wau, mau, neverActive: users.length - lastActive.size },
      versions,
      latestBuild,
      repoVersion: repo,
      usersOnLatest,
      usersBehind,
      usersUnknownBuild,
      usersWithoutDevices,
      locales,
      platforms,
      tokenAges,
      pushReachability,
      signups: series(users.map((u) => u.created_at), 30),
      posts: series(posts.map((p) => p.created_at), 30),
      outbox: {
        pending,
        sentLast24h: outbox7d.filter((n) => n.sent_at !== null && n.sent_at >= since24h).length,
        byKindLast7d: [...groupCount(outbox7d, (n) => n.kind)]
          .map(([kind, count]) => ({ kind, count }))
          .sort((a, b) => b.count - a.count),
      },
      optOuts,
    };

    res.json(body);
  } catch (error) {
    next(error);
  }
});
