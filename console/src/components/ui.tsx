import type { ReactNode } from 'react';

export function Card({ label, value, hint }: { label: string; value: ReactNode; hint?: ReactNode }) {
  return (
    <div className="card">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
      {hint ? <div className="hint">{hint}</div> : null}
    </div>
  );
}

export function Bars({ points }: { points: { date: string; count: number }[] }) {
  const max = Math.max(1, ...points.map((p) => p.count));
  return (
    <div className="bars">
      {points.map((p) => (
        <div
          key={p.date}
          className={p.count === max && max > 0 ? 'hot' : undefined}
          style={{ height: `${Math.round((p.count / max) * 100)}%` }}
          title={`${p.date}: ${p.count}`}
        />
      ))}
    </div>
  );
}

export function Fail({ message, onRetry }: { message: string; onRetry?: () => void }) {
  return (
    <div className="error">
      <div>{message}</div>
      {onRetry ? (
        <div style={{ marginTop: 10 }}>
          <button onClick={onRetry}>Повторить</button>
        </div>
      ) : null}
    </div>
  );
}

export function ago(iso: string | null): string {
  if (!iso) return '—';
  const ms = Date.now() - Date.parse(iso);
  const minutes = Math.round(ms / 60000);
  if (minutes < 1) return 'только что';
  if (minutes < 60) return `${minutes} мин назад`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} ч назад`;
  const days = Math.round(hours / 24);
  if (days < 45) return `${days} дн назад`;
  return new Date(iso).toLocaleDateString('ru-RU');
}

// В списке время суток только шумит и рвёт колонку на две строки — там
// нужен день, в карточке уже и время.
export function day(iso: string | null): string {
  return iso ? new Date(iso).toLocaleDateString('ru-RU') : '—';
}

export function date(iso: string | null): string {
  return iso ? new Date(iso).toLocaleString('ru-RU', { dateStyle: 'short', timeStyle: 'short' }) : '—';
}
