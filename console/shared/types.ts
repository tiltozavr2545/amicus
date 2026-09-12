// Контракт между локальным API консоли и её же фронтендом. Один файл на оба
// конца, чтобы поля не разъехались.

export type Totals = {
  users: number;
  posts: number;
  comments: number;
  reactions: number;
  connections: number;
  rooms: number;
  roomMessages: number;
  devices: number;
};

export type SeriesPoint = { date: string; count: number };

export type VersionRow = {
  version: string | null;
  build: number | null;
  installs: number;
  users: number;
};

export type OverviewResponse = {
  generatedAt: string;
  totals: Totals;
  activity: { dau: number; wau: number; mau: number; neverActive: number };
  versions: VersionRow[];
  latestBuild: number | null;
  repoVersion: { name: string; build: number } | null;
  usersOnLatest: number;
  usersBehind: number;
  usersUnknownBuild: number;
  usersWithoutDevices: number;
  locales: { locale: string; installs: number }[];
  platforms: { platform: string; installs: number; users: number }[];
  tokenAges: { bucket: string; tokens: number; users: number }[];
  pushReachability: { state: string; users: number }[];
  signups: SeriesPoint[];
  posts: SeriesPoint[];
  outbox: { pending: number; sentLast24h: number; byKindLast7d: { kind: string; count: number }[] };
  optOuts: { setting: string; users: number }[];
};

export type UserRow = {
  id: string;
  name: string;
  email: string | null;
  isSystem: boolean;
  createdAt: string;
  lastActiveAt: string | null;
  lastSignInAt: string | null;
  emailConfirmed: boolean;
  banned: boolean;
  posts: number;
  comments: number;
  connections: number;
  devices: number;
  maxBuild: number | null;
  versions: string[];
  locales: string[];
  platforms: string[];
  /** Чем закончилась последняя попытка зарегистрировать пуш-токен.
   *  null — человек ещё не открывал версию, которая это сообщает. */
  pushStatus: string | null;
  pushStatusAt: string | null;
  pushStatusDetail: string | null;
};

export type UsersResponse = {
  generatedAt: string;
  total: number;
  users: UserRow[];
};

export type DeviceRow = {
  tokenTail: string;
  locale: string;
  platform: string | null;
  osVersion: string | null;
  appVersion: string | null;
  appBuild: number | null;
  createdAt: string;
  updatedAt: string;
};

export type PostPreview = {
  id: string;
  text: string | null;
  createdAt: string;
  visibility: string | null;
  media: number;
};

export type UserDetailResponse = {
  user: UserRow;
  devices: DeviceRow[];
  preferences: Record<string, boolean> | null;
  counts: {
    posts: number;
    comments: number;
    reactions: number;
    connections: number;
    rooms: number;
    roomMessages: number;
    profilePhotos: number;
    invites: number;
    blockedBy: number;
    mutedBy: number;
    favoritedBy: number;
  };
  recentPosts: PostPreview[];
  recentNotifications: { kind: string; createdAt: string; sentAt: string | null }[];
};

export type ApiError = { error: string };

export type ModerationTargetKind = 'post' | 'comment' | 'room_message';

export type ReportMedia = {
  /** image | video — чем рисовать превью. */
  kind: string;
  /** Подписанная ссылка на сам объект. Живёт час. */
  url: string | null;
  /** Постер видео, если он есть: само видео в карточке не проигрывается. */
  posterUrl: string | null;
  path: string;
};

export type ReportRow = {
  id: string;
  reporterId: string;
  reporterName: string;
  targetKind: string;
  targetId: string;
  targetAuthorId: string | null;
  targetAuthorName: string | null;
  targetAuthorBanned: boolean;
  targetSnapshot: string | null;
  /** Медиа объекта, на который жалуются: у поста — из post_media, у
   *  сообщения — из его jsonb. У комментария медиа не бывает. */
  media: ReportMedia[];
  /** Жив ли объект: автор мог снести его раньше разбора. */
  targetExists: boolean;
  targetHidden: boolean;
  /** Сколько всего жалоб на этот же объект — одна и семь читаются по-разному. */
  reportsOnTarget: number;
  /** Сколько жалоб подал сам жалобщик за всё время и сколько отклонили. */
  reporterTotal: number;
  reporterRejected: number;
  reason: string;
  note: string | null;
  createdAt: string;
  status: string;
  resolution: string | null;
  resolvedAt: string | null;
};

export type ReportsResponse = {
  generatedAt: string;
  open: number;
  reports: ReportRow[];
};

export type NewsMedia = {
  mediaType: string;
  storagePath: string;
  posterPath: string | null;
  /** Подписанные ссылки живут час; у черновика их нет, пока он не открыт. */
  url?: string | null;
  posterUrl?: string | null;
};

export type NewsPost = {
  id: string;
  text: string | null;
  createdAt: string;
  hidden: boolean;
  comments: number;
  reactions: number;
  media: NewsMedia[];
};

export type NewsDraft = {
  id: string;
  text: string;
  media: NewsMedia[];
  updatedAt: string;
};

export type NewsResponse = {
  generatedAt: string;
  authorId: string;
  posts: NewsPost[];
  drafts: NewsDraft[];
};

export type BroadcastTarget = {
  userId: string;
  name: string;
  /** Максимальный app_build среди устройств; null — ни одно не сообщило. */
  maxBuild: number | null;
  locale: string;
};

export type BroadcastResponse = {
  generatedAt: string;
  repoVersion: { name: string; build: number } | null;
  targetBuild: number;
  willReceive: BroadcastTarget[];
  /** Отсеяны защитой от повтора: про эту сборку им уже клали уведомление. */
  skippedAlready: BroadcastTarget[];
  /** Отсеяны своей настройкой notify_system_account. */
  skippedOptOut: BroadcastTarget[];
  /** У скольких людей нет устройств вовсе — до них не дойдёт ничто. */
  withoutDevices: number;
  history: { build: string; kind: string; users: number }[];
};
