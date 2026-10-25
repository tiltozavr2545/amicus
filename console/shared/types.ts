// Contract between the console's local API and its own frontend. One file
// for both ends so the fields don't drift apart.

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
  outbox: {
    pending: number;
    sentLast24h: number;
    byKindLast7d: { kind: string; count: number }[];
  };
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
  /** How the latest attempt to register a push token ended.
   *  null — the person hasn't opened a version that reports it yet. */
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
  recentNotifications: {
    kind: string;
    createdAt: string;
    sentAt: string | null;
  }[];
};

export type ApiError = { error: string };

export type ModerationTargetKind = 'post' | 'comment' | 'room_message';

export type ReportMedia = {
  /** image | video — how to render the preview. */
  kind: string;
  /** Signed URL to the object itself. Lives for an hour. */
  url: string | null;
  /** Video poster, if any: the video itself isn't played in the card. */
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
  /** Media of the reported object: for a post — from post_media, for a
   *  message — from its jsonb. Comments never have media. */
  media: ReportMedia[];
  /** Whether the object still exists: the author may have deleted it before review. */
  targetExists: boolean;
  targetHidden: boolean;
  /** Total reports on the same object — one and seven read differently. */
  reportsOnTarget: number;
  /** How many reports the reporter has filed in total, and how many were rejected. */
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
  /**
   * Object path in the bucket — for everything already published. For
   * something not yet published it's `staged:<name>`: the file sits on the
   * console's disk and moves to the bucket on publish (see STAGING in
   * `server/news.ts`).
   */
  storagePath: string;
  posterPath: string | null;
  /**
   * What to display it with. For an object in the bucket — a signed URL that
   * lives for an hour; for a staged file — `/api/news/media/<name>`, which
   * doesn't expire.
   */
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
  /** Highest app_build across devices; null — none has reported one. */
  maxBuild: number | null;
  locale: string;
};

export type BroadcastResponse = {
  generatedAt: string;
  repoVersion: { name: string; build: number } | null;
  targetBuild: number;
  willReceive: BroadcastTarget[];
  /** Filtered out by the repeat guard: already notified about this build. */
  skippedAlready: BroadcastTarget[];
  /** Filtered out by their own notify_system_account setting. */
  skippedOptOut: BroadcastTarget[];
  /** How many people have no devices at all — nothing will reach them. */
  withoutDevices: number;
  history: { build: string; kind: string; users: number }[];
};
