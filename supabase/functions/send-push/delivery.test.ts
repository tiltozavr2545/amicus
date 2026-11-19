import { deepEqual, equal } from 'node:assert/strict';
import { test } from 'node:test';
import {
  type ClaimedNotification,
  DeliveryProgress,
  retryAfterTimestamp,
} from './delivery.ts';

const now = Date.parse('2026-11-18T18:00:00Z');

function notification(
  overrides: Partial<ClaimedNotification> = {},
): ClaimedNotification {
  return {
    id: 'notification',
    user_id: 'recipient',
    kind: 'room_message',
    payload: {},
    claimed_at: new Date(now).toISOString(),
    settled_deliveries: {},
    delivery_attempts: 0,
    ...overrides,
  };
}

test('retries a temporary failure without repeating settled deliveries', () => {
  const progress = new DeliveryProgress(notification());
  progress.record('accepted', { status: 'sent' });
  progress.record('expired', { status: 'stale' });
  progress.record('unavailable', {
    status: 'retry',
    reason: 'FCM HTTP 503',
    retryAfter: now + 120_000,
  });

  const update = progress.finish(now, 0);
  equal(update.failed, false);
  equal(update.attempts, 1);
  equal(update.next_attempt_at, '2026-11-18T18:02:00.000Z');
  deepEqual(update.settled_deliveries, { accepted: null, expired: null });

  const retry = new DeliveryProgress(notification({
    settled_deliveries: update.settled_deliveries,
    delivery_attempts: update.attempts,
  }));
  equal(retry.hasSettled('accepted'), true);
  equal(retry.hasSettled('unavailable'), false);
  retry.record('unavailable', { status: 'sent' });
  equal(retry.finish(now, 0).next_attempt_at, null);
  equal(retry.finish(now, 0).last_error, null);
});

test('backs off between retry attempts and records exhaustion as failure', () => {
  const failure = { status: 'retry', reason: 'FCM HTTP 429', retryAfter: 0 } as const;
  const second = new DeliveryProgress(notification({ delivery_attempts: 1 }));
  second.record('device', failure);
  equal(second.finish(now, 0).next_attempt_at, '2026-11-18T18:02:00.000Z');

  const last = new DeliveryProgress(notification({ delivery_attempts: 5 }));
  last.record('device', failure);
  const update = last.finish(now, 0);
  equal(update.next_attempt_at, null);
  equal(update.failed, true);
  equal(update.last_error, 'FCM HTTP 429');
});

test('persists permanent failures across retries of other devices', () => {
  const progress = new DeliveryProgress(notification({
    settled_deliveries: { refused: 'FCM HTTP 400' },
    delivery_attempts: 1,
  }));
  equal(progress.hasSettled('refused'), true);
  progress.record('recovered', { status: 'sent' });
  const update = progress.finish(now, 0);
  equal(update.failed, true);
  equal(update.next_attempt_at, null);
  equal(update.last_error, 'FCM HTTP 400');
});

test('understands both forms of Retry-After', () => {
  equal(retryAfterTimestamp('120', now), now + 120_000);
  equal(retryAfterTimestamp('Wed, 18 Nov 2026 18:02:00 GMT', now), now + 120_000);
  equal(retryAfterTimestamp('not a delay', now), 0);
});
