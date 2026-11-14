/// Whether a string looks enough like a uuid to be worth sending to the DB.
///
/// It exists precisely because PostgREST is not the place to find out the
/// shape of an identifier. A malformed id reaches Postgres, which answers
/// `22P02 invalid input syntax for type uuid`, `db.ts` wraps that in an
/// `Error`, and the handler in `index.ts` turns ANY throw into a 500 with the
/// driver's text. So a typo in an id looked the same as a crashed server — and
/// the very same endpoint that honestly answers 404 for a normal nonexistent
/// id answered 500 with bits of internals for a garbage one.
///
/// This isn't about security: the id goes as a PostgREST filter parameter, not
/// spliced into SQL, and a garbage one simply finds no rows. It's about making
/// the response mean what it says.
///
/// We check the canonical shape (8-4-4-4-12), without braces and without the
/// urn prefix: nothing in this project produces those, and accepting more than
/// you produce means making a decision for the DB that it didn't ask for.
/// Case doesn't matter: Postgres compares uuids by value, not by spelling.
import type { RequestParamHandler } from 'express';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === 'string' && UUID.test(value);
}

/// `router.param('id', uuidParam)` — checks `:id` once per router, not as a
/// copy in every handler. A copy lasts until someone forgets it in a new
/// endpoint, and the forgotten one silently returns exactly that 500 with the
/// driver's text that `isUuid` was introduced to prevent. It fires for every
/// route of the router whose path has `:id`, including ones added later.
export const uuidParam: RequestParamHandler = (_req, res, next, value) => {
  if (!isUuid(value)) {
    res.status(400).json({ error: 'id должен быть uuid' });
    return;
  }
  next();
};
