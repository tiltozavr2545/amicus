import express from 'express';
import type { NextFunction, Request, Response } from 'express';
import { env } from './env.ts';
import { overviewRouter } from './routes/overview.ts';
import { broadcastRouter } from './routes/broadcast.ts';
import { moderationRouter } from './routes/moderation.ts';
import { newsRouter } from './routes/news.ts';
import { usersRouter } from './routes/users.ts';

const app = express();
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

// Только петля. Консоль ходит service_role-ключом, то есть мимо RLS целиком:
// один случайный `0.0.0.0` в кафе — и вся база у соседа по Wi-Fi.
app.listen(env.apiPort, '127.0.0.1', () => {
  console.log(`[api] http://127.0.0.1:${env.apiPort} → ${env.supabaseUrl}`);
});
