import type { ReactNode } from 'react';

export function Card({
  label,
  value,
  hint,
}: {
  label: string;
  value: ReactNode;
  hint?: ReactNode;
}) {
  return (
    <div className="card">
      <div className="label">{label}</div>
      <div className="value">{value}</div>
      {hint ? <div className="hint">{hint}</div> : null}
    </div>
  );
}

export function PageHead({
  title,
  meta,
  children,
}: {
  title: string;
  meta?: ReactNode;
  children?: ReactNode;
}) {
  return (
    <header className="page-head">
      <div>
        <h1>{title}</h1>
        {meta ? <div className="stamp">{meta}</div> : null}
      </div>
      {children ? <div className="page-actions">{children}</div> : null}
    </header>
  );
}

export function Loading({ children }: { children: ReactNode }) {
  return (
    <p className="loading" role="status">
      {children}
    </p>
  );
}

export function Fail({
  message,
  onRetry,
}: {
  message: string;
  onRetry?: () => void;
}) {
  return (
    <div className="error" role="alert">
      <strong>Не удалось загрузить данные</strong>
      <div>{message}</div>
      {onRetry ? (
        <div style={{ marginTop: 10 }}>
          <button type="button" onClick={onRetry}>
            Повторить
          </button>
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

// In a list the time of day is just noise and breaks the column into two
// lines — the day is what matters there; the detail card shows the time too.
export function day(iso: string | null): string {
  return iso ? new Date(iso).toLocaleDateString('ru-RU') : '—';
}

export function date(iso: string | null): string {
  return iso
    ? new Date(iso).toLocaleString('ru-RU', {
        dateStyle: 'short',
        timeStyle: 'short',
      })
    : '—';
}
