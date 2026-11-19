export type DeliveryOutcome =
  | { status: 'sent' | 'stale' }
  | { status: 'failed'; reason: string }
  | { status: 'retry'; reason: string; retryAfter: number };

export type ClaimedNotification = {
  id: string;
  user_id: string;
  kind: string;
  payload: Record<string, unknown>;
  claimed_at: string;
  settled_deliveries: Record<string, string | null>;
  delivery_attempts: number;
};

const MAX_ATTEMPTS = 6;

export class DeliveryProgress {
  private readonly row: ClaimedNotification;
  private readonly settled: Record<string, string | null>;
  private readonly retryErrors = new Map<string, string>();
  private retryAfter = 0;
  deferred = false;

  constructor(row: ClaimedNotification) {
    this.row = row;
    this.settled = { ...row.settled_deliveries };
  }

  hasSettled(tokenHash: string): boolean {
    return Object.hasOwn(this.settled, tokenHash);
  }

  record(tokenHash: string, result: DeliveryOutcome) {
    if (result.status === 'retry') {
      this.retryErrors.set(tokenHash, result.reason);
      this.retryAfter = Math.max(this.retryAfter, result.retryAfter);
    } else {
      this.settled[tokenHash] = result.status === 'failed' ? result.reason : null;
    }
  }

  finish(now: number, jitterMs: number) {
    const attempts =
      this.row.delivery_attempts + Number(this.retryErrors.size > 0);
    const exhausted = this.retryErrors.size > 0 && attempts >= MAX_ATTEMPTS;
    if (exhausted) {
      for (const [hash, error] of this.retryErrors) this.settled[hash] = error;
    }
    const errors = new Set(this.retryErrors.values());
    for (const error of Object.values(this.settled)) {
      if (error !== null) errors.add(error);
    }

    const willRetry = this.retryErrors.size > 0 && !exhausted;
    let nextAttempt = null;
    if (willRetry || this.deferred) {
      const backoff = willRetry ? 60_000 * 2 ** (attempts - 1) : 0;
      const retryAfter = willRetry ? this.retryAfter : 0;
      nextAttempt = new Date(
        Math.max(now + backoff + jitterMs, retryAfter),
      ).toISOString();
    }
    return {
      id: this.row.id,
      claimed_at: this.row.claimed_at,
      settled_deliveries: this.settled,
      attempts,
      next_attempt_at: nextAttempt,
      failed: nextAttempt === null && errors.size > 0,
      last_error: errors.size > 0 ? [...errors].sort().join(', ') : null,
    };
  }
}

export function retryAfterTimestamp(header: string | null, now: number): number {
  if (header === null) return 0;
  const value = header.trim();
  const at = /^\d+$/.test(value) ? now + Number(value) * 1000 : Date.parse(value);
  return Number.isFinite(at) && at > now && at <= 8.64e15 ? at : 0;
}
