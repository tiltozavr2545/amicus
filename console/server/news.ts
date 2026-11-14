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

// Drafts live in a file next to the console, not in the database, and that's
// deliberate: the console is local and single-user, a draft is a personal note
// on this machine, not app state. A table for it would require a migration,
// policies and grants for data that nobody but the one person at this laptop
// will ever read.
const DRAFTS = resolve(here, '..', 'drafts.json');

// Bytes that haven't become a post yet live next to the drafts, for the same
// reason.
//
// The selected file used to go to the bucket right away, at the moment of
// selection, and the draft stored its `posts/<systemId>/…` path. That's
// exactly what made drafts unviable: an object without a row in `post_media`
// is referenced by nobody, i.e. by the definition of `orphaned_media_paths()`
// (20260829110000) it's an orphan, and the hourly `reap-orphaned-media` wiped
// the bytes after a day. Publishing a two-day-old draft still succeeded,
// though: the `post_media` rows went in pointing at nothing, and the post went
// out to the feed of every connection with broken pictures — along with the
// push already sent. There was nothing to restore it from: `drafts.json` is the
// only copy of a draft.
//
// Hence the rule: **a draft doesn't reference the bucket**. The file lives
// here until a post is made from it, and goes to the bucket at publish time
// (`prepareMedia`). As a bonus, the whole "the console littered the bucket"
// class disappears: an abandoned set of files never gets there at all.
const STAGING = resolve(here, '..', 'news-staging');

// The marker of a path that points here rather than at the bucket. The colon
// in the prefix was chosen because it never occurs in a Storage object key —
// so a staged ref can't be confused with a real path in either direction.
const STAGED_PREFIX = 'staged:';

// What a staged file name looks like: a uuid plus an extension, nothing more.
//
// This isn't nitpicking about form but the only check between a string from
// the request and a filesystem `resolve()`. The name comes from outside — the
// client sends back what we gave it, but "gave" is no guarantee here — and
// without the `^…$` anchors `../../` would get through. The name is issued by
// the server whole (uuid plus an extension from the type table), so the
// pattern describes exactly what can occur.
const STAGED_NAME =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.[a-z0-9]{2,5}$/;

// How long an abandoned staged file stays before it's cleared out.
//
// "Abandoned" doesn't mean "from a draft": whatever a draft references lives
// as long as the draft does (see `pruneStaging`). What gets cleared is what
// was selected and never turned into anything — neither a post nor a draft —
// because the tab was closed. A week, not a day: the cost of a mistake here is
// the opposite of what it was for the bucket, and it's better to err on the
// side of an extra file on our own disk.
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
    // The file doesn't exist yet or is corrupted — an empty list is more
    // honest than crashing the whole section over a note.
    return [];
  }
}

export async function writeDrafts(drafts: Draft[]): Promise<void> {
  await writeFile(DRAFTS, JSON.stringify(drafts, null, 2), 'utf8');
}

/// Whether the path refers to a staged file rather than a bucket object.
export function isStaged(path: string): boolean {
  return path.startsWith(STAGED_PREFIX);
}

/// The staged file name from a ref to it, or null if the ref isn't ours.
///
/// The only way to turn an incoming string into a file name: everything else
/// in this module takes an already-checked name.
export function stagedName(path: string): string | null {
  if (!isStaged(path)) return null;
  const name = path.slice(STAGED_PREFIX.length);
  return STAGED_NAME.test(name) ? name : null;
}

/// The ref a staged file travels under in a draft and in a request body.
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

/// Clears out staged files that nothing references and that nobody will need
/// anymore.
///
/// [referenced] — names held by drafts; they're never touched, however old.
/// Everything else is removed by age: fresh files survive, because they may be
/// sitting unsaved in the composer right now.
///
/// Swallows its own errors: this is cleanup on a local disk, and a failed
/// cleanup is no reason to bring down the news section.
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
    // The directory doesn't exist yet (no file has been selected), or a file
    // was pulled out from under us between readdir and stat.
  }
}

// What the `media` bucket accepts (see storage.buckets): checked here, not only
// on the Storage server, so the person learns about a refusal before a
// hundred-megabyte file goes over the network.
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

// Extension by type — via a table, and only via a table.
//
// The keys are exactly ALLOWED_MIME, so there's no way to miss it: the caller
// has already refused everything not listed here. The values are pairwise
// distinct, so the table also reads in reverse (`mimeForExtension`), and
// that's exactly why the extension is NO longer taken from the submitted file
// name: a staged file sits on disk under its own extension, and the
// `contentType` for the bucket upload is recovered from it. The name from the
// request plays no part in computing the path at all — neither in the object
// key nor in the file name.
//
// The previous derivation (`mime.split('/')[1]` with a separate branch for
// `quicktime`) also produced `x-matroska`, which isn't an extension in any
// sense.
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

/// The extension a file of this type is stored under, both in staging and in
/// the bucket.
export function extensionForMime(mime: string): string {
  return EXTENSION_BY_MIME[mime] ?? 'bin';
}

/// The reverse: what to declare as the content type of a staged file uploaded
/// to the bucket.
///
/// The bucket checks `allowed_mime_types`, so lying here means getting a
/// refusal on upload; `null` for an unknown extension is more honest than
/// `application/octet-stream`, which the bucket won't accept anyway.
export function mimeForExtension(name: string): string | null {
  const ext = name.slice(name.lastIndexOf('.') + 1).toLowerCase();
  return MIME_BY_EXTENSION[ext] ?? null;
}
