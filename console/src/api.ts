import { useCallback, useEffect, useState } from 'react';

export async function get<T>(path: string): Promise<T> {
  const response = await fetch(`/api${path}`);
  const body = await response.json().catch(() => ({ error: 'Ответ не разобрать' }));
  if (!response.ok) throw new Error((body as { error?: string }).error ?? response.statusText);
  return body as T;
}

export type Loadable<T> = {
  data: T | null;
  error: string | null;
  loading: boolean;
  reload: () => void;
};

export function useApi<T>(path: string): Loadable<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [nonce, setNonce] = useState(0);

  useEffect(() => {
    let alive = true;
    setLoading(true);
    get<T>(path)
      .then((result) => {
        if (!alive) return;
        setData(result);
        setError(null);
      })
      .catch((e: Error) => {
        if (!alive) return;
        setError(e.message);
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [path, nonce]);

  const reload = useCallback(() => setNonce((n) => n + 1), []);
  return { data, error, loading, reload };
}
