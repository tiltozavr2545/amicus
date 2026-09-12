import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const PUBSPEC = resolve(here, '..', '..', 'app', 'pubspec.yaml');

// Консоль лежит в том же репозитории, что и приложение, — значит может
// сказать не только «какой максимум сообщили устройства», но и «что вообще
// собрано». Расхождение между этими числами и есть интересное: установка не
// может сообщить сборку, которой нет в pubspec, если её номер не подняли
// где-то по дороге к стору.
export async function repoVersion(): Promise<{ name: string; build: number } | null> {
  try {
    const text = await readFile(PUBSPEC, 'utf8');
    const match = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$/m.exec(text);
    if (!match) return null;
    return { name: match[1], build: Number(match[2]) };
  } catch {
    return null;
  }
}
