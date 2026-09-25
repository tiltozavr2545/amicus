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

export const newsRouter = Router();

// Id системного аккаунта спрашивается у базы (`system_account_ids()`), а не
// лежит копией в коде консоли — по той же причине, по которой его не носит в
// себе APK.
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

/// Заливает staged-файл в бакет и отдаёт его настоящий путь.
///
/// Имя объекта — само имя staged-файла, то есть стабильное: опубликовать один
/// и тот же черновик дважды значит второй раз прийти по тому же пути с теми же
/// байтами, и 409 здесь — это «уже там», а не отказ. Тот же вывод и то же
/// послабление, что у `uploadTolerant` в приложении.
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
  // `upsert: false` и повторная публикация того же черновика — штатная пара,
  // а не сбой. Код смотрим и в `statusCode`, и в тексте: у StorageError форма
  // ответа зависит от версии storage-api, а обозначает оба одно и то же.
  const status = (error as { statusCode?: string }).statusCode;
  if (status === '409' || /already exists/i.test(error.message)) return path;
  throw new Error(`storage: ${error.message}`);
}

// Повторяет проверки `create_post_with_media()`, потому что сама она здесь
// неприменима: она берёт автора из `auth.uid()`, а консоль ходит под
// service_role без JWT — auth.uid() там null, и функция сразу отказывает.
// Значит вставка идёт напрямую, и всё, что RPC проверяла, надо проверить
// тут же: иначе в базу попадёт то, чего клиент туда положить не мог.
//
// Здесь же staged-файлы превращаются в объекты бакета — публикация и есть тот
// момент, когда байтам там место (см. STAGING в news.ts). До него путь в
// присланном элементе указывает на диск консоли, после — в бакет, и дальше по
// коду разницы уже нет.
//
// Путь для нового объекта минтит сервер, а не клиент: единственное, что
// приходит снаружи, — имя staged-файла, и оно проверено шаблоном. Прежняя
// редакция принимала `storage_path` строкой и проверяла у неё только префикс.
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

  /// Один путь: staged-файл заливается, путь в бакет проверяется.
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

  // Пустая строка от клиента — это отсутствие текста, а не текст: тот же
  // nullif(btrim(...)), что стоит в posts_text_not_blank.
  return { text: trimmed === '' ? null : trimmed, media: normalised };
}

/// Чем показать медиа черновика.
///
/// Staged-файл отдаёт сама консоль, и такая ссылка не протухает — в отличие от
/// подписанной, которая живёт час, так что миниатюры сохранённого черновика
/// были битыми уже к обеду. Настоящий путь (черновик, сохранённый до перехода
/// на стейджинг) всё ещё подписывается, чтобы такие черновики не ослепли
/// разом; если объекта уже нет — `null`, и плитка просто пустая.
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
  // Набор переписывается целиком, а не доливается — как в
  // `create_post_with_media()`: `position` раздаётся по порядку массива, и
  // оставшиеся старые строки заняли бы чужие места.
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

    // Уборка стейджинга висит здесь, а не на своём расписании: раздел новостей
    // — единственное место, откуда туда что-то попадает, и открыть его до
    // того, как файл станет лишним, невозможно. То, на что ссылается хоть один
    // черновик, не трогается вовсе; остальное сносится по возрасту.
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

// Файл приходит сырым телом, а не multipart: разбирать multipart значит
// тащить зависимость ради одного поля. Тип едет в query — его и надо-то знать,
// чтобы проверить, примет ли бакет, и выбрать расширение.
//
// Файл ложится на диск консоли, а НЕ в бакет: в бакет он уедет из
// `prepareMedia()`, когда из него будут делать пост. Почему так — см. STAGING
// в news.ts; коротко: у объекта без строки в `post_media` нет ничего, что
// удержало бы его от `reap-orphaned-media`, поэтому сохранённый черновик
// терял свои картинки ровно через сутки.
//
// `name` больше не читается. Расширение берётся из типа по таблице, то есть
// путь целиком минтит сервер: имя файла из браузера в него не попадает ни
// одним символом — а оно попадало, и вместе с ним `..` в имя на диске.
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

// Превью staged-файла. Ссылка не подписанная и не протухает — в отличие от
// той, что раньше сохранялась внутрь черновика и переставала работать через
// час.
//
// `stagedName()` — единственное, что стоит между параметром маршрута и
// `resolve()` по файловой системе, поэтому отказ здесь 404, а не попытка
// что-нибудь прочитать.
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
    // `media` обязателен явным списком, и это не придирка к форме запроса.
    // Правка переписывает набор медиа целиком (иначе `position` раздать
    // нечем), поэтому отсутствующее поле означает «медиа больше нет» — то
    // есть запрос, забывший его указать, молча сносит вложения. Поймано
    // дважды на живом посте новостного аккаунта: PATCH с одним только
    // `text` обнулял набор и переписывал текст.
    if (!Array.isArray(req.body?.media)) {
      res.status(400).json({
        error:
          'Правка переписывает медиа целиком — пришли media списком, даже пустым',
      });
      return;
    }
    // Проверка владельца — ДО `prepareMedia`, а не после. Раньше порядок был
    // обратный и ничего не стоил, потому что `normalise` только смотрела на
    // строки. Теперь она заливает staged-файлы в бакет, и правка поста,
    // которого нет, успевала бы оставить там объекты, на которые уже некому
    // сослаться, — то есть ровно тех сирот, от которых этот раздел только что
    // ушёл.
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
    // Файлы из бакета не трогаем: на них больше никто не ссылается, и их
    // вынесет `reap-orphaned-media` в течение суток. Удалять байты руками —
    // единственное действие в этой схеме, которое нельзя отменить.
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});

newsRouter.put('/news/drafts', async (req, res, next) => {
  try {
    // Не-массив — это ошибка запроса, а НЕ «черновиков больше нет». Прежняя
    // редакция подставляла на его месте пустой список и молча стирала файл
    // целиком: тот же класс, что и PATCH без `media`, только цена выше —
    // черновик восстановить неоткуда, он нигде больше не хранится.
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
