import { Router } from 'express';
import type {
  DeviceRow,
  PostPreview,
  UserDetailResponse,
  UserRow,
  UsersResponse,
} from '../../shared/types.ts';
import { admin } from '../supabase.ts';
import { countOf, fetchAll, fetchAuthUsers, fetchOnce } from '../db.ts';
import { loadDevices, systemAccountIds } from '../aggregate.ts';

export const usersRouter = Router();

type PublicUser = { id: string; name: string; created_at: string };

async function buildRows(): Promise<UserRow[]> {
  const [users, auth, activity, devices, posts, comments, connections, system] =
    await Promise.all([
      fetchAll<PublicUser>('users', 'id, name, created_at'),
      fetchAuthUsers(),
      fetchAll<{ user_id: string; last_active_at: string }>(
        'user_activity',
        'user_id, last_active_at',
      ),
      loadDevices(),
      fetchAll<{ author_id: string }>('posts', 'author_id'),
      fetchAll<{ author_id: string }>('comments', 'author_id', (q: any) =>
        q.is('deleted_at', null),
      ),
      fetchAll<{ user_a_id: string; user_b_id: string }>(
        'connections',
        'user_a_id, user_b_id',
      ),
      systemAccountIds(),
    ]);

    // Почему у человека нет токена — единственный источник ответа на это
    // (20260913120000). Раньше «отказал в разрешении» и «у нас упала запись»
    // выглядели снаружи одинаково: строки просто нет.
    const pushStatus = new Map(
      (
        await fetchAll<{
          user_id: string;
          status: string;
          platform: string | null;
          os_version: string | null;
          app_version: string | null;
          app_build: number | null;
          detail: string | null;
          updated_at: string;
        }>('push_registration_status', '*')
      ).map((r) => [r.user_id, r]),
    );

  const bump = (map: Map<string, number>, key: string) =>
    map.set(key, (map.get(key) ?? 0) + 1);

  const postCount = new Map<string, number>();
  for (const p of posts) bump(postCount, p.author_id);
  const commentCount = new Map<string, number>();
  for (const c of comments) bump(commentCount, c.author_id);
  const connectionCount = new Map<string, number>();
  for (const c of connections) {
    bump(connectionCount, c.user_a_id);
    bump(connectionCount, c.user_b_id);
  }

  const deviceByUser = new Map<string, typeof devices>();
  for (const d of devices) {
    const list = deviceByUser.get(d.user_id) ?? [];
    list.push(d);
    deviceByUser.set(d.user_id, list);
  }
  const activeAt = new Map(activity.map((a) => [a.user_id, a.last_active_at]));

  return users.map((u) => {
    const mine = deviceByUser.get(u.id) ?? [];
    const builds = mine
      .map((d) => d.app_build)
      .filter((b): b is number => b !== null);
    const authRow = auth.get(u.id);
    const push = pushStatus.get(u.id);
    const bannedUntil = authRow?.bannedUntil;
    return {
      id: u.id,
      name: u.name,
      email: authRow?.email ?? null,
      isSystem: system.has(u.id),
      createdAt: u.created_at,
      lastActiveAt: activeAt.get(u.id) ?? null,
      lastSignInAt: authRow?.lastSignInAt ?? null,
      emailConfirmed: Boolean(authRow?.emailConfirmedAt),
      banned: Boolean(bannedUntil && Date.parse(bannedUntil) > Date.now()),
      posts: postCount.get(u.id) ?? 0,
      comments: commentCount.get(u.id) ?? 0,
      connections: connectionCount.get(u.id) ?? 0,
      devices: mine.length,
      // У человека без токенов версия и платформа берутся из статуса
      // регистрации: `device_tokens` их не знает по определению — колонки
      // там появляются только при УСПЕШНОЙ регистрации, то есть у тех, про
      // кого и так всё понятно.
      maxBuild: builds.length
        ? Math.max(...builds)
        : push?.app_build ?? null,
      versions: mine.length
        ? [...new Set(mine.map((d) => d.app_version).filter((v): v is string => !!v))]
        : push?.app_version
          ? [push.app_version]
          : [],
      locales: [...new Set(mine.map((d) => d.locale))],
      platforms: mine.length
        ? [...new Set(mine.map((d) => d.platform).filter((p): p is string => !!p))]
        : push?.platform
          ? [push.platform]
          : [],
      pushStatus: push?.status ?? null,
      pushStatusAt: push?.updated_at ?? null,
      pushStatusDetail: push?.detail ?? null,
    };
  });
}

usersRouter.get('/users', async (_req, res, next) => {
  try {
    const users = await buildRows();
    const body: UsersResponse = {
      generatedAt: new Date().toISOString(),
      total: users.length,
      users,
    };
    res.json(body);
  } catch (error) {
    next(error);
  }
});

usersRouter.get('/users/:id', async (req, res, next) => {
  try {
    const id = req.params.id;
    const rows = await buildRows();
    const user = rows.find((u) => u.id === id);
    if (!user) {
      res.status(404).json({ error: 'Пользователь не найден' });
      return;
    }

    const [devices, prefsRows, recentPostRows, notifications] = await Promise.all([
      fetchOnce<{
        fcm_token: string;
        locale: string;
        app_version: string | null;
        app_build: number | null;
        platform: string | null;
        os_version: string | null;
        created_at: string;
        updated_at: string;
      }>(
        'device_tokens',
        'fcm_token, locale, app_version, app_build, platform, os_version, created_at, updated_at',
        (q: any) => q.eq('user_id', id).order('updated_at', { ascending: false }),
      ),
      fetchOnce<Record<string, unknown>>('notification_preferences', '*', (q: any) =>
        q.eq('user_id', id),
      ),
      fetchOnce<{ id: string; text: string | null; created_at: string; visibility: string | null }>(
        'posts',
        'id, text, created_at, visibility',
        (q: any) => q.eq('author_id', id).order('created_at', { ascending: false }).limit(20),
      ),
      fetchOnce<{ kind: string; created_at: string; sent_at: string | null }>(
        'notification_outbox',
        'kind, created_at, sent_at',
        (q: any) => q.eq('user_id', id).order('created_at', { ascending: false }).limit(20),
      ),
    ]);

    const postIds = recentPostRows.map((p) => p.id);
    const media = postIds.length
      ? await fetchOnce<{ post_id: string }>('post_media', 'post_id', (q: any) =>
          q.in('post_id', postIds),
        )
      : [];
    const mediaCount = new Map<string, number>();
    for (const m of media) mediaCount.set(m.post_id, (mediaCount.get(m.post_id) ?? 0) + 1);

    const [
      reactions,
      roomMemberships,
      roomMessages,
      profilePhotos,
      invites,
      blockedBy,
      mutedBy,
      favoritedBy,
    ] = await Promise.all([
      countOf('reactions', (q: any) => q.eq('user_id', id)),
      countOf('room_members', (q: any) => q.eq('user_id', id)),
      countOf('room_messages', (q: any) => q.eq('author_id', id).is('deleted_at', null)),
      countOf('profile_photos', (q: any) => q.eq('user_id', id)),
      countOf('invite_links', (q: any) => q.eq('owner_id', id)),
      countOf('blocked_users', (q: any) => q.eq('blocked_id', id)),
      countOf('muted_users', (q: any) => q.eq('muted_id', id)),
      countOf('favorite_users', (q: any) => q.eq('favorite_id', id)),
    ]);

    const prefs = prefsRows[0];
    const preferences = prefs
      ? Object.fromEntries(
          Object.entries(prefs).filter(([k, v]) => k !== 'user_id' && typeof v === 'boolean'),
        )
      : null;

    const recentPosts: PostPreview[] = recentPostRows.map((p) => ({
      id: p.id,
      text: p.text,
      createdAt: p.created_at,
      visibility: p.visibility,
      media: mediaCount.get(p.id) ?? 0,
    }));

    const deviceRows: DeviceRow[] = devices.map((d) => ({
      // Сам токен консоли не нужен ни для чего — показываем хвост, чтобы
      // отличать устройства друг от друга, и не держим его на экране.
      tokenTail: d.fcm_token.slice(-8),
      locale: d.locale,
      platform: d.platform,
      osVersion: d.os_version,
      appVersion: d.app_version,
      appBuild: d.app_build,
      createdAt: d.created_at,
      updatedAt: d.updated_at,
    }));

    const body: UserDetailResponse = {
      user,
      devices: deviceRows,
      preferences: preferences as Record<string, boolean> | null,
      counts: {
        posts: user.posts,
        comments: user.comments,
        reactions,
        connections: user.connections,
        rooms: roomMemberships,
        roomMessages,
        profilePhotos,
        invites,
        blockedBy,
        mutedBy,
        favoritedBy,
      },
      recentPosts,
      recentNotifications: notifications.map((n) => ({
        kind: n.kind,
        createdAt: n.created_at,
        sentAt: n.sent_at,
      })),
    };

    res.json(body);
  } catch (error) {
    next(error);
  }
});

// Заглушка «проверить связь»: сервер поднялся и ключ рабочий.
usersRouter.get('/health', async (_req, res, next) => {
  try {
    const { error } = await admin.from('users').select('id', { head: true, count: 'exact' });
    if (error) throw new Error(error.message);
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});
