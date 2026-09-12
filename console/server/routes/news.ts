import { randomUUID } from 'node:crypto';
import { Router, raw } from 'express';
import type { NewsMedia, NewsPost, NewsResponse } from '../../shared/types.ts';
import { admin } from '../supabase.ts';
import { fetchOnce } from '../db.ts';
import { systemAccountIds } from '../aggregate.ts';
import {
  ALLOWED_MIME,
  MAX_FILE_BYTES,
  MAX_MEDIA_PER_POST,
  extensionFor,
  readDrafts,
  writeDrafts,
} from '../news.ts';
import type { Draft } from '../news.ts';

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

// Повторяет проверки `create_post_with_media()`, потому что сама она здесь
// неприменима: она берёт автора из `auth.uid()`, а консоль ходит под
// service_role без JWT — auth.uid() там null, и функция сразу отказывает.
// Значит вставка идёт напрямую, и всё, что RPC проверяла, надо проверить
// тут же: иначе в базу попадёт то, чего клиент туда положить не мог.
async function normalise(
  text: unknown,
  media: unknown,
): Promise<{ text: string | null; media: Required<NewsMedia>[] }> {
  const trimmed = typeof text === 'string' ? text.trim() : '';
  const items = Array.isArray(media) ? (media as IncomingMedia[]) : [];

  if (items.length > MAX_MEDIA_PER_POST) {
    throw new Error(`Медиа больше ${MAX_MEDIA_PER_POST} — столько пост не примет`);
  }
  if (trimmed === '' && items.length === 0) {
    throw new Error('Посту нужен текст или медиа');
  }

  const prefix = `posts/${await systemId()}/`;
  const normalised = items.map((item, index) => {
    const mediaType = item.mediaType === 'video' ? 'video' : 'image';
    const storagePath = String(item.storagePath ?? '');
    const posterPath = item.posterPath ? String(item.posterPath) : null;
    if (!storagePath.startsWith(prefix)) {
      throw new Error(`Файл ${index + 1} лежит вне префикса ${prefix}`);
    }
    if (posterPath !== null && !posterPath.startsWith(prefix)) {
      throw new Error(`Постер файла ${index + 1} лежит вне префикса ${prefix}`);
    }
    return { mediaType, storagePath, posterPath, url: null, posterUrl: null };
  });

  // Пустая строка от клиента — это отсутствие текста, а не текст: тот же
  // nullif(btrim(...)), что стоит в posts_text_not_blank.
  return { text: trimmed === '' ? null : trimmed, media: normalised };
}

async function signed(paths: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  if (paths.length === 0) return out;
  const { data, error } = await admin.storage.from('media').createSignedUrls(paths, 3600);
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
  const { error: wipeError } = await admin.from('post_media').delete().eq('post_id', postId);
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
    }>('posts', 'id, text, created_at, hidden_at', (q: any) =>
      q.eq('author_id', author).order('created_at', { ascending: false }).limit(50),
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
          (q: any) => q.in('post_id', ids).order('position', { ascending: true }),
        )
      : [];

    const urls = await signed(
      media.flatMap((m) => (m.poster_path ? [m.storage_path, m.poster_path] : [m.storage_path])),
    );

    const [comments, reactions] = await Promise.all([
      ids.length
        ? fetchOnce<{ post_id: string }>('comments', 'post_id', (q: any) =>
            q.in('post_id', ids).is('deleted_at', null),
          )
        : [],
      ids.length
        ? fetchOnce<{ post_id: string }>('reactions', 'post_id', (q: any) => q.in('post_id', ids))
        : [],
    ]);
    const tally = (rows: { post_id: string }[]) => {
      const map = new Map<string, number>();
      for (const r of rows) map.set(r.post_id, (map.get(r.post_id) ?? 0) + 1);
      return map;
    };
    const commentCount = tally(comments);
    const reactionCount = tally(reactions);

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
            posterUrl: m.poster_path ? urls.get(m.poster_path) ?? null : null,
          })),
      })),
      drafts: await readDrafts(),
    };
    res.json(body);
  } catch (error) {
    next(error);
  }
});

// Файл приходит сырым телом, а не multipart: разбирать multipart значит
// тащить зависимость ради одного поля. Имя и тип едут в query — их и надо-то
// знать, чтобы выбрать расширение и проверить, примет ли бакет.
newsRouter.post(
  '/news/media',
  raw({ type: '*/*', limit: MAX_FILE_BYTES + 1024 * 1024 }),
  async (req, res, next) => {
    try {
      const mime = String(req.query.type ?? '');
      const name = String(req.query.name ?? 'file');
      const body = req.body as Buffer;

      if (!ALLOWED_MIME.has(mime)) {
        res.status(400).json({ error: `Бакет не принимает ${mime || 'файл без типа'}` });
        return;
      }
      if (!Buffer.isBuffer(body) || body.length === 0) {
        res.status(400).json({ error: 'Пустое тело запроса' });
        return;
      }
      if (body.length > MAX_FILE_BYTES) {
        res.status(400).json({ error: 'Файл больше 100 МиБ — бакет столько не примет' });
        return;
      }

      // Тот же префикс, что требует `create_post_with_media()` и storage-политика.
      const path = `posts/${await systemId()}/${randomUUID()}.${extensionFor(mime, name)}`;
      const { error } = await admin.storage.from('media').upload(path, body, {
        contentType: mime,
        upsert: false,
      });
      if (error) throw new Error(`storage: ${error.message}`);

      const url = (await signed([path])).get(path) ?? null;
      res.json({ path, url, mediaType: mime.startsWith('video/') ? 'video' : 'image' });
    } catch (error) {
      next(error);
    }
  },
);

newsRouter.post('/news', async (req, res, next) => {
  try {
    const { text, media } = await normalise(req.body?.text, req.body?.media);
    const author = await systemId();

    const inserted = await admin
      .from('posts')
      .insert({ author_id: author, text, client_token: randomUUID(), visibility: 'connections' })
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
        error: 'Правка переписывает медиа целиком — пришли media списком, даже пустым',
      });
      return;
    }
    const { text, media } = await normalise(req.body?.text, req.body?.media);
    const author = await systemId();

    const existing = await fetchOnce<{ id: string }>('posts', 'id', (q: any) =>
      q.eq('id', req.params.id).eq('author_id', author),
    );
    if (existing.length === 0) {
      res.status(404).json({ error: 'Пост не найден или принадлежит не новостному аккаунту' });
      return;
    }

    const { error } = await admin.from('posts').update({ text }).eq('id', req.params.id);
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
      res.status(400).json({ error: 'drafts обязателен списком — пустой список тоже список' });
      return;
    }
    const drafts = req.body.drafts as Draft[];
    await writeDrafts(drafts);
    res.json({ ok: true });
  } catch (error) {
    next(error);
  }
});
