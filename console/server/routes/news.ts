import { randomUUID } from 'node:crypto';
import { Router, raw } from 'express';
import type {
  NewsDraft,
  NewsMedia,
  NewsPost,
  NewsResponse,
} from '../../shared/types.ts';
import { systemAccountIds } from '../aggregate.ts';
import { fetchOnce } from '../db.ts';
import type { Draft } from '../news.ts';
import {
  ALLOWED_MIME,
  extensionForMime,
  isStaged,
  MAX_FILE_BYTES,
  MAX_MEDIA_PER_POST,
  mimeForExtension,
  pruneStaging,
  readDrafts,
  readStaged,
  stagedName,
  stagedRef,
  writeDrafts,
  writeStaged,
} from '../news.ts';
import { admin } from '../supabase.ts';
import { uuidParam } from '../uuid.ts';

export const newsRouter = Router();
newsRouter.param('id', uuidParam);

// The system account id is asked from the database (`system_account_ids()`)
// rather than kept as a copy in the console code — for the same reason the APK
// doesn't carry it either.
let cachedSystemId: string | null = null;
async function systemId(): Promise<string> {
  if (cachedSystemId) return cachedSystemId;
  const ids = await systemAccountIds();
  const first = [...ids][0];
  if (!first) throw new Error('system_account_ids() ничего не вернула');
  cachedSystemId = first;
  return first;
}

type IncomingMedia = {
  mediaType?: unknown;
  storagePath?: unknown;
  posterPath?: unknown;
};

/// Uploads a staged file to the bucket and returns its real path.
///
/// The object name is the staged file's own name, i.e. stable: publishing the
/// same draft twice means arriving at the same path with the same bytes the
/// second time, and a 409 here means "already there", not a refusal. Same
/// reasoning and same leniency as `uploadTolerant` in the app.
async function materialise(name: string, author: string): Promise<string> {
  const path = `posts/${author}/${name}`;
  const contentType = mimeForExtension(name);
  if (contentType === null) {
    throw new Error(`Файл ${name} — неизвестный тип, бакет его не примет`);
  }
  const { error } = await admin.storage
    .from('media')
    .upload(path, await readStaged(name), { contentType, upsert: false });
  if (error === null) return path;
  // `upsert: false` plus republishing the same draft is a normal combination,
  // not a failure. We check the code both in `statusCode` and in the text: the
  // StorageError response shape depends on the storage-api version, and both
  // mean the same thing.
  const status = (error as { statusCode?: string }).statusCode;
  if (status === '409' || /already exists/i.test(error.message)) return path;
  throw new Error(`storage: ${error.message}`);
}

// Repeats the checks of `create_post_with_media()`, because the function itself
// can't be used here: it takes the author from `auth.uid()`, while the console
// runs as service_role without a JWT — auth.uid() is null there, and the
// function refuses right away. So the insert goes in directly, and everything
// the RPC checked has to be checked right here: otherwise the database would
// get something the client couldn't have put there.
//
// This is also where staged files turn into bucket objects — publishing is
// exactly the moment the bytes belong there (see STAGING in news.ts). Before
// it, the path in the submitted item points at the console's disk, after it —
// at the bucket, and from there on the code makes no distinction.
//
// The path for a new object is minted by the server, not the client: the only
// thing coming from outside is the staged file name, and it's checked against
// a pattern. The previous version accepted `storage_path` as a string and
// checked only its prefix.
async function prepareMedia(
  text: unknown,
  media: unknown,
): Promise<{ text: string | null; media: Required<NewsMedia>[] }> {
  const trimmed = typeof text === 'string' ? text.trim() : '';
  const items = Array.isArray(media) ? (media as IncomingMedia[]) : [];

  if (items.length > MAX_MEDIA_PER_POST) {
    throw new Error(
      `Медиа больше ${MAX_MEDIA_PER_POST} — столько пост не примет`,
    );
  }
  if (trimmed === '' && items.length === 0) {
    throw new Error('Посту нужен текст или медиа');
  }

  const author = await systemId();
  const prefix = `posts/${author}/`;

  /// One path: a staged file gets uploaded, a bucket path gets checked.
  const resolvePath = async (raw: string, what: string): Promise<string> => {
    if (isStaged(raw)) {
      const name = stagedName(raw);
      if (name === null) throw new Error(`${what}: испорченная ссылка`);
      return materialise(name, author);
    }
    if (!raw.startsWith(prefix)) {
      throw new Error(`${what} лежит вне префикса ${prefix}`);
    }
    return raw;
  };

  const normalised: Required<NewsMedia>[] = [];
  for (const [index, item] of items.entries()) {
    const mediaType = item.mediaType === 'video' ? 'video' : 'image';
    const storagePath = await resolvePath(
      String(item.storagePath ?? ''),
      `Файл ${index + 1}`,
    );
    const posterPath = item.posterPath
      ? await resolvePath(String(item.posterPath), `Постер файла ${index + 1}`)
      : null;
    normalised.push({
      mediaType,
      storagePath,
      posterPath,
      url: null,
      posterUrl: null,
    });
  }

  // An empty string from the client means no text, not text: the same
  // nullif(btrim(...)) as in posts_text_not_blank.
  return { text: trimmed === '' ? null : trimmed, media: normalised };
}

/// What to show a draft's media with.
///
/// A staged file is served by the console itself, and such a link doesn't
/// expire — unlike a signed one, which lives an hour, so a saved draft's
/// thumbnails were broken by lunchtime. A real path (a draft saved before the
/// switch to staging) is still signed, so such drafts don't all go blind at
/// once; if the object is already gone — `null`, and the tile is just empty.
async function draftMediaUrls(drafts: Draft[]): Promise<NewsDraft[]> {
  const legacy = new Set<string>();
  for (const draft of drafts) {
    for (const item of draft.media) {
      for (const path of [item.storagePath, item.posterPath]) {
        if (path && !isStaged(path)) legacy.add(path);
      }
    }
  }
  const urls = await signed([...legacy]);
  const urlFor = (path: string | null): string | null => {
    if (!path) return null;
    const name = stagedName(path);
    if (name !== null) return `/api/news/media/${name}`;
    return urls.get(path) ?? null;
  };
  return drafts.map((draft) => ({
    ...draft,
    media: draft.media.map((item) => ({
      ...item,
      url: urlFor(item.storagePath),
      posterUrl: urlFor(item.posterPath),
    })),
  }));
}

async function signed(paths: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (paths.length === 0) return out;
  const { data, error } = await admin.storage
    .from('media')
    .createSignedUrls(paths, 3600);
  if (error) throw new Error(`storage: ${error.message}`);
  for (const entry of data ?? []) {
    if (entry.path && entry.signedUrl) out.set(entry.path, entry.signedUrl);
  }
  return out;
}

async function replaceMedia(postId: string, media: Required<NewsMedia>[]) {
  // The set is rewritten whole, not appended to — as in
  // `create_post_with_media()`: `position` is assigned in array order, and
  // leftover old rows would take other items' places.
  const { error: wipeError } = await admin
    .from('post_media')
    .delete()
    .eq('post_id', postId);
  if (wipeError) throw new Error(`post_media: ${wipeError.message}`);
  if (media.length === 0) return;
  const { error } = await admin.from('post_media').insert(
    media.map((m, index) => ({
      post_id: postId,
      position: index,
      media_type: m.mediaType,
      storage_path: m.storagePath,
      poster_path: m.posterPath,
    })),
  );
  if (error) throw new Error(`post_media: ${error.message}`);
}

newsRouter.get('/news', async (_req, res, next) => {
  try {
    const author = await systemId();
    const posts = await fetchOnce<{
      id: string;
      text: string | null;
      created_at: string;
      hidden_at: string | null;
    }>('posts', 'id, text, created_at, hidden_at', (q) =>
      q
        .eq('author_id', author)
        .order('created_at', { ascending: false })
        .limit(50),
    );

    const ids = posts.map((p) => p.id);
    const media = ids.length
      ? await fetchOnce<{
          post_id: string;
          position: number;
          media_type: string;
          storage_path: string;
          poster_path: string | null;
        }>(
          'post_media',
          'post_id, position, media_type, storage_path, poster_path',
          (q) => q.in('post_id', ids).order('position', { ascending: true }),
        )
      : [];

    const urls = await signed(
      media.flatMap((m) =>
        m.poster_path ? [m.storage_path, m.poster_path] : [m.storage_path],
      ),
    );

    const [comments, reactions] = await Promise.all([
      ids.length
        ? fetchOnce<{ post_id: string }>('comments', 'post_id', (q) =>
            q.in('post_id', ids).is('deleted_at', null),
          )
        : [],
      ids.length
        ? fetchOnce<{ post_id: string }>('reactions', 'post_id', (q) =>
            q.in('post_id', ids),
          )
        : [],
    ]);
    const tally = (rows: { post_id: string }[]) => {
      const map = new Map<string, number>();
      for (const r of rows) map.set(r.post_id, (map.get(r.post_id) ?? 0) + 1);
      return map;
    };
    const commentCount = tally(comments);
    const reactionCount = tally(reactions);

    // Staging cleanup hangs here rather than on its own schedule: the news
    // section is the only place anything gets in there from, and it's
    // impossible to open it before a file becomes unneeded. Anything referenced
    // by at least one draft isn't touched at all; the rest is removed by age.
    const drafts = await readDrafts();
    const referenced = new Set<string>();
    for (const draft of drafts) {
      for (const item of draft.media) {
        for (const path of [item.storagePath, item.posterPath]) {
          const name = path === null ? null : stagedName(path);
          if (name !== null) referenced.add(name);
        }
      }
    }
    await pruneStaging(referenced);

    const body: NewsResponse = {
      generatedAt: new Date().toISOString(),
      authorId: author,
      posts: posts.map<NewsPost>((p) => ({
        id: p.id,
        text: p.text,
        createdAt: p.created_at,
        hidden: p.hidden_at !== null,
        comments: commentCount.get(p.id) ?? 0,
        reactions: reactionCount.get(p.id) ?? 0,
        media: media
          .filter((m) => m.post_id === p.id)
          .map((m) => ({
            mediaType: m.media_type,
            storagePath: m.storage_path,
            posterPath: m.poster_path,
            url: urls.get(m.storage_path) ?? null,
            posterUrl: m.poster_path ? (urls.get(m.poster_path) ?? null) : null,
          })),
      })),
      drafts: await draftMediaUrls(drafts),
    };
    res.json(body);
  } catch (error) {
    next(error);
  }
});

// The file arrives as a raw body, not multipart: parsing multipart means
// pulling in a dependency for one field. The type travels in the query — it's
// only needed to check whether the bucket will accept it and to pick the
// extension.
//
// The file lands on the console's disk, NOT in the bucket: it goes to the
// bucket from `prepareMedia()`, when a post is made from it. For why, see
// STAGING in news.ts; in short: an object without a row in `post_media` has
// nothing keeping it from `reap-orphaned-media`, so a saved draft lost its
// pictures after exactly a day.
//
// `name` is no longer read. The extension comes from the type via a table, so
// the whole path is minted by the server: not a single character of the
// browser's file name gets into it — and it used to, bringing `..` into the
// name on disk with it.
newsRouter.post(
  '/news/media',
  raw({ type: '*/*', limit: MAX_FILE_BYTES + 1024 * 1024 }),
  async (req, res, next) => {
    try {
      const mime = String(req.query.type ?? '');
      const body = req.body as Buffer;

      if (!ALLOWED_MIME.has(mime)) {
        res
          .status(400)
          .json({ error: `Бакет не принимает ${mime || 'файл без типа'}` });
        return;
      }
      if (!Buffer.isBuffer(body) || body.length === 0) {
        res.status(400).json({ error: 'Пустое тело запроса' });
        return;
      }
      if (body.length > MAX_FILE_BYTES) {
        res
          .status(400)
          .json({ error: 'Файл больше 100 МиБ — бакет столько не примет' });
        return;
      }

      const name = `${randomUUID()}.${extensionForMime(mime)}`;
      await writeStaged(name, body);
      res.json({
        path: stagedRef(name),
        url: `/api/news/media/${name}`,
        mediaType: mime.startsWith('video/') ? 'video' : 'image',
      });
    } catch (error) {
      next(error);
    }
  },
);

// Preview of a staged file. The link isn't signed and doesn't expire — unlike
// the one that used to be saved inside the draft and stopped working after an
// hour.
//
// `stagedName()` is the only thing standing between the route parameter and a
// filesystem `resolve()`, so a refusal here is a 404, not an attempt to read
// something.
newsRouter.get('/news/media/:name', async (req, res, next) => {
  try {
    const name = stagedName(stagedRef(req.params.name));
    const contentType = name === null ? null : mimeForExtension(name);
    if (name === null || contentType === null) {
      res.status(404).json({ error: 'Нет такого файла' });
      return;
    }
    let bytes: Buffer;
    try {
      bytes = await readStaged(name);
    } catch {
      res.status(404).json({ error: 'Нет такого файла' });
      return;
    }
    res.type(contentType).send(bytes);
  } catch (error) {
    next(error);
  }
});

newsRouter.post('/news', async (req, res, next) => {
  try {
    const { text, media } = await prepareMedia(req.body?.text, req.body?.media);
    const author = await systemId();

    const inserted = await admin
      .from('posts')
      .insert({
        author_id: author,
        text,
        client_token: randomUUID(),
        visibility: 'connections',
      })
      .select('id')
      .single();
    if (inserted.error) throw new Error(`posts: ${inserted.error.message}`);

    await replaceMedia(inserted.data.id as string, media);
    res.json({ ok: true, id: inserted.data.id });
  } catch (error) {
    next(error);
  }
});

newsRouter.patch('/news/:id', async (req, res, next) => {
  try {
    // `media` is required as an explicit list, and that's not nitpicking about
    // the request shape. An edit rewrites the media set whole (otherwise
    // there's nothing to assign `position` from), so a missing field means
    // "no more media" — i.e. a request that forgot it silently wipes the
    // attachments. Caught twice on a live post of the news account: a PATCH
    // with only `text` emptied the set and rewrote the text.
    if (!Array.isArray(req.body?.media)) {
      res.status(400).json({
        error:
          'Правка переписывает медиа целиком — пришли media списком, даже пустым',
      });
      return;
    }
    // The owner check goes BEFORE `prepareMedia`, not after. The order used
    // to be reversed and cost nothing, because `normalise` only looked at
    // strings. Now it uploads staged files to the bucket, and an edit of a
    // post that doesn't exist would manage to leave objects there that nothing
    // can reference anymore — exactly the orphans this section just got away
    // from.
    const author = await systemId();
    const existing = await fetchOnce<{ id: string }>('posts', 'id', (q) =>
      q.eq('id', req.params.id).eq('author_id', author),
    );
    if (existing.length === 0) {
      res.status(404).json({
        error: 'Пост не найден или не принадлежит новостному аккаунту',
      });
      return;
    }

    const { text, media } = await prepareMedia(req.body?.text, req.body?.media);

    const { error } = await admin
      .from('posts')
      .update({ text })
      .eq('id', req.params.id);
    if (error) throw new Error(`posts: ${error.message}`);
    await replaceMedia(req.params.id, media);
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

newsRouter.delete('/news/:id', async (req, res, next) => {
  try {
    const author = await systemId();
    const { error } = await admin
      .from('posts')
      .delete()
      .eq('id', req.params.id)
      .eq('author_id', author);
    if (error) throw new Error(`posts: ${error.message}`);
    // We don't touch the bucket files: nothing references them anymore, and
    // `reap-orphaned-media` will clear them out within a day. Deleting bytes
    // by hand is the only action in this scheme that can't be undone.
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

newsRouter.put('/news/drafts', async (req, res, next) => {
  try {
    // A non-array is a request error, NOT "there are no more drafts". The
    // previous version substituted an empty list in its place and silently
    // wiped the whole file: the same class as a PATCH without `media`, only
    // costlier — there's nowhere to restore a draft from, it isn't stored
    // anywhere else.
    if (!Array.isArray(req.body?.drafts)) {
      res.status(400).json({
        error: 'drafts обязателен списком — пустой список тоже список',
      });
      return;
    }
    const drafts = req.body.drafts as Draft[];
    await writeDrafts(drafts);
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});
