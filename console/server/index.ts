import type { NextFunction, Request, Response } from 'express';
import express from 'express';
import { env } from './env.ts';
import { localOnly } from './local_only.ts';
import { broadcastRouter } from './routes/broadcast.ts';
import { moderationRouter } from './routes/moderation.ts';
import { newsRouter } from './routes/news.ts';
import { overviewRouter } from './routes/overview.ts';
import { usersRouter } from './routes/users.ts';

const app = express();
// Before body parsing: the check looks only at headers, and there is no point
// parsing a megabyte of JSON from a request that is about to be rejected. For
// why the loopback binding below doesn't cover this on its own, see
// local_only.ts.
app.use(localOnly);
app.use(express.json({ limit: '1mb' }));

app.use('/api', overviewRouter);
app.use('/api', usersRouter);
app.use('/api', moderationRouter);
app.use('/api', newsRouter);
app.use('/api', broadcastRouter);

app.use((_req, res) => {
  res.status(404).json({ error: 'Нет такого метода' });
});

app.use((error: unknown, _req: Request, res: Response, _next: NextFunction) => {
  const message = error instanceof Error ? error.message : String(error);
  console.error('[api]', message);
  res.status(500).json({ error: message });
});

// Loopback only. The console uses the service_role key, i.e. bypasses RLS
// entirely: one stray `0.0.0.0` in a cafe and the whole database is open to
// the Wi-Fi neighbour.
app.listen(env.apiPort, '127.0.0.1', () => {
  console.log(`[api] http://127.0.0.1:${env.apiPort} → ${env.supabaseUrl}`);
});
