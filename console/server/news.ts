import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

// Черновики лежат файлом рядом с консолью, а не в базе, и это осознанно:
// консоль локальная и однопользовательская, черновик — личная заметка на
// этой машине, а не состояние приложения. Таблица ради него потребовала бы
// миграции, политик и грантов на данные, которые никто, кроме одного
// человека за этим ноутбуком, никогда не прочитает.
const DRAFTS = resolve(here, '..', 'drafts.json');

export type Draft = {
  id: string;
  text: string;
  media: { mediaType: string; storagePath: string; posterPath: string | null }[];
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

export const MAX_FILE_BYTES = 104857600;
export const MAX_MEDIA_PER_POST = 20;

export function extensionFor(mime: string, fallbackName: string): string {
  const fromName = fallbackName.includes('.')
    ? fallbackName.slice(fallbackName.lastIndexOf('.') + 1).toLowerCase()
    : '';
  if (fromName.length >= 2 && fromName.length <= 5) return fromName;
  const guess = mime.split('/')[1] ?? 'bin';
  return guess === 'quicktime' ? 'mov' : guess;
}
