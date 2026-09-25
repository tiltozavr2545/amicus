import {
  mkdir,
  readdir,
  readFile,
  stat,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

// Черновики лежат файлом рядом с консолью, а не в базе, и это осознанно:
// консоль локальная и однопользовательская, черновик — личная заметка на
// этой машине, а не состояние приложения. Таблица ради него потребовала бы
// миграции, политик и грантов на данные, которые никто, кроме одного
// человека за этим ноутбуком, никогда не прочитает.
const DRAFTS = resolve(here, '..', 'drafts.json');

// Байты, ещё не ставшие постом, — рядом с черновиками и по той же причине.
//
// Раньше выбранный файл уезжал в бакет сразу, в момент выбора, и черновик
// хранил его `posts/<systemId>/…` путь. Ровно это и делало черновик
// нежизнеспособным: на объект, у которого нет строки в `post_media`, не
// ссылается никто, то есть по определению `orphaned_media_paths()`
// (20260829110000) он сирота, и ежечасный `reap-orphaned-media` сносил байты
// через сутки. Публикация двухдневного черновика при этом проходила успешно:
// строки `post_media` вставали, указывая в пустоту, и пост уходил в ленту
// всем знакомым с битыми картинками — вместе с уже отправленным пушем.
// Вернуть было нечего, `drafts.json` — единственная копия черновика.
//
// Отсюда правило: **черновик не ссылается в бакет**. Файл живёт здесь, пока
// из него не сделают пост, и в бакет уезжает в момент публикации
// (`prepareMedia`). Заодно исчезает и весь класс «консоль насорила в бакет»:
// брошенный набор файлов больше вообще туда не попадает.
const STAGING = resolve(here, '..', 'news-staging');

// Чем помечен путь, который указывает сюда, а не в бакет. Двоеточие в
// префиксе выбрано потому, что его не бывает в ключе объекта Storage, — то
// есть перепутать staged-ссылку с настоящим путём нельзя ни в одну сторону.
const STAGED_PREFIX = 'staged:';

// Как выглядит имя staged-файла: uuid плюс расширение, и ничего больше.
//
// Это не придирка к форме, а единственная проверка между строкой из запроса и
// `resolve()` по файловой системе. Имя приходит снаружи — клиент шлёт обратно
// то, что мы ему выдали, но «выдали» здесь не гарантия, — и без якорей `^…$`
// сюда прошло бы `../../`. Имя выдаётся сервером целиком (uuid плюс
// расширение по таблице типов), так что шаблон описывает ровно то, что бывает.
const STAGED_NAME =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{2,5}$/;

// Сколько брошенный staged-файл лежит, прежде чем его вынесут.
//
// «Брошенный» — это не «из черновика»: на что ссылается черновик, живёт,
// сколько живёт черновик (см. `pruneStaging`). Выносится то, что выбрали и
// ни во что не превратили — ни в пост, ни в черновик, — потому что вкладку
// закрыли. Неделя, а не сутки: цена ошибки здесь противоположна той, что была
// у бакета, и промахнуться лучше в сторону лишнего файла на своём же диске.
const STAGED_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000;

export type Draft = {
  id: string;
  text: string;
  media: {
    mediaType: string;
    storagePath: string;
    posterPath: string | null;
  }[];
  updatedAt: string;
};

export async function readDrafts(): Promise<Draft[]> {
  try {
    const parsed = JSON.parse(await readFile(DRAFTS, 'utf8'));
    return Array.isArray(parsed) ? (parsed as Draft[]) : [];
  } catch {
    // Файла ещё нет или он испорчен — пустой список честнее, чем падение
    // всего раздела из-за заметки.
    return [];
  }
}

export async function writeDrafts(drafts: Draft[]): Promise<void> {
  await writeFile(DRAFTS, JSON.stringify(drafts, null, 2), 'utf8');
}

/// Ссылается ли путь на staged-файл, а не на объект в бакете.
export function isStaged(path: string): boolean {
  return path.startsWith(STAGED_PREFIX);
}

/// Имя staged-файла из ссылки на него, или null, если ссылка не наша.
///
/// Единственный способ превратить пришедшую строку в имя файла: всё остальное
/// в этом модуле принимает уже проверенное имя.
export function stagedName(path: string): string | null {
  if (!isStaged(path)) return null;
  const name = path.slice(STAGED_PREFIX.length);
  return STAGED_NAME.test(name) ? name : null;
}

/// Ссылка, под которой staged-файл ездит в черновике и в теле запроса.
export function stagedRef(name: string): string {
  return `${STAGED_PREFIX}${name}`;
}

export async function writeStaged(name: string, bytes: Buffer): Promise<void> {
  await mkdir(STAGING, { recursive: true });
  await writeFile(resolve(STAGING, name), bytes);
}

export function readStaged(name: string): Promise<Buffer> {
  return readFile(resolve(STAGING, name));
}

/// Выносит staged-файлы, на которые никто не ссылается и которые никому уже
/// не пригодятся.
///
/// [referenced] — имена, занятые черновиками; они не трогаются, сколько бы им
/// ни было лет. Всё остальное сносится по возрасту: свежее живёт, потому что
/// прямо сейчас может лежать в композере несохранённым.
///
/// Свои ошибки глотает: это уборка на локальном диске, и провалившаяся уборка
/// не повод ронять раздел новостей.
export async function pruneStaging(referenced: Set<string>): Promise<void> {
  try {
    const names = await readdir(STAGING);
    const deadline = Date.now() - STAGED_MAX_AGE_MS;
    for (const name of names) {
      if (referenced.has(name)) continue;
      const file = resolve(STAGING, name);
      const info = await stat(file);
      if (info.mtimeMs >= deadline) continue;
      await unlink(file);
    }
  } catch {
    // Каталога ещё нет (ни одного файла не выбирали), или файл увели из-под
    // нас между readdir и stat.
  }
}

// Что принимает бакет `media` (см. storage.buckets): проверяется здесь, а не
// только на сервере Storage, чтобы человек узнал об отказе до того, как
// стомегабайтный файл уедет по сети.
export const ALLOWED_MIME = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/heic',
  'image/heif',
  'video/mp4',
  'video/quicktime',
  'video/x-m4v',
  'video/3gpp',
  'video/webm',
  'video/x-matroska',
]);

// Расширение по типу — таблицей, и только таблицей.
//
// Ключи — ровно ALLOWED_MIME, то есть промахнуться мимо неё неоткуда:
// вызывающий уже отказал всему, чего здесь нет. Значения попарно различны,
// поэтому таблица читается и в обратную сторону (`mimeForExtension`), а это и
// есть то, ради чего расширение больше НЕ берётся из присланного имени файла:
// staged-файл лежит на диске под своим расширением, и по нему же
// восстанавливается `contentType` при заливке в бакет. Имя из запроса в
// вычислении пути не участвует вовсе — ни в ключе объекта, ни в имени файла.
//
// Прежний вывод (`mime.split('/')[1]` с отдельной веткой на `quicktime`)
// давал ещё и `x-matroska`, что не расширение ни в каком смысле.
const EXTENSION_BY_MIME: Record<string, string> = {
  'image/jpeg': 'jpg',
  'image/png': 'png',
  'image/webp': 'webp',
  'image/heic': 'heic',
  'image/heif': 'heif',
  'video/mp4': 'mp4',
  'video/quicktime': 'mov',
  'video/x-m4v': 'm4v',
  'video/3gpp': '3gp',
  'video/webm': 'webm',
  'video/x-matroska': 'mkv',
};

const MIME_BY_EXTENSION: Record<string, string> = Object.fromEntries(
  Object.entries(EXTENSION_BY_MIME).map(([mime, ext]) => [ext, mime]),
);

export const MAX_FILE_BYTES = 104857600;
export const MAX_MEDIA_PER_POST = 20;

/// Расширение, под которым файл этого типа лежит и в стейджинге, и в бакете.
export function extensionForMime(mime: string): string {
  return EXTENSION_BY_MIME[mime] ?? 'bin';
}

/// Обратно: чем объявлять содержимое staged-файла, залитого в бакет.
///
/// Бакет проверяет `allowed_mime_types`, так что соврать здесь — значит
/// получить отказ на заливке; `null` для незнакомого расширения честнее
/// `application/octet-stream`, который бакет всё равно не примет.
export function mimeForExtension(name: string): string | null {
  const ext = name.slice(name.lastIndexOf('.') + 1).toLowerCase();
  return MIME_BY_EXTENSION[ext] ?? null;
}
