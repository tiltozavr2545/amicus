import { readFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const PUBSPEC = resolve(here, '..', '..', 'app', 'pubspec.yaml');

// The console lives in the same repository as the app, so it can say not only
// "what maximum the devices have reported" but also "what has actually been
// built". The discrepancy between those numbers is the interesting part: an
// install can't report a build that isn't in pubspec unless its number was
// bumped somewhere on the way to the store.
export async function repoVersion(): Promise<{
  name: string;
  build: number;
} | null> {
  try {
    const text = await readFile(PUBSPEC, 'utf8');
    const match = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$/m.exec(
      text,
    );
    if (!match) return null;
    return { name: match[1], build: Number(match[2]) };
  } catch {
    return null;
  }
}
