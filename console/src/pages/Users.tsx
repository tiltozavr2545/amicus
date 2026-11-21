import { useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import type { UserRow, UsersResponse } from '../../shared/types';
import { useApi } from '../api';
import { ago, date, day, Fail, Loading, PageHead } from '../components/ui';

type SortKey =
  | 'name'
  | 'createdAt'
  | 'lastActiveAt'
  | 'posts'
  | 'comments'
  | 'connections'
  | 'maxBuild';

const COLUMNS: { key: SortKey | null; title: string; num?: boolean }[] = [
  { key: 'name', title: 'Имя' },
  { key: null, title: 'Почта' },
  { key: 'createdAt', title: 'Регистрация' },
  { key: 'lastActiveAt', title: 'Заходил' },
  { key: 'maxBuild', title: 'Версия' },
  { key: null, title: 'ОС' },
  { key: null, title: 'Язык' },
  { key: 'posts', title: 'Посты', num: true },
  { key: 'comments', title: 'Комм.', num: true },
  { key: 'connections', title: 'Знак.', num: true },
];

function compare(a: UserRow, b: UserRow, key: SortKey): number {
  const av = a[key];
  const bv = b[key];
  if (av === null) return 1;
  if (bv === null) return -1;
  if (typeof av === 'number' && typeof bv === 'number') return bv - av;
  return String(bv).localeCompare(String(av), 'ru');
}

export function Users() {
  const { data, error, loading, reload } = useApi<UsersResponse>('/users');
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<SortKey>('createdAt');

  const rows = useMemo(() => {
    if (!data) return [];
    const needle = query.trim().toLowerCase();
    const filtered = needle
      ? data.users.filter((u) =>
          [u.name, u.email ?? '', u.id].some((field) =>
            field.toLowerCase().includes(needle),
          ),
        )
      : data.users;
    return [...filtered].sort((a, b) => compare(a, b, sort));
  }, [data, query, sort]);

  if (error) return <Fail message={error} onRetry={reload} />;
  if (!data) return <Loading>Загружаю пользователей…</Loading>;

  return (
    <>
      <PageHead
        title="Пользователи"
        meta={`Показано ${rows.length} из ${data.total}. Данные на ${date(data.generatedAt)}`}
      >
        <input
          type="search"
          aria-label="Поиск пользователей"
          placeholder="Имя, почта или ID"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />

        <button type="button" onClick={reload} disabled={loading}>
          {loading ? 'Обновляю…' : 'Обновить'}
        </button>
      </PageHead>

      <section
        className="panel table-panel"
        // biome-ignore lint/a11y/noNoninteractiveTabindex: keyboard users need to scroll wide tables.
        tabIndex={0}
        aria-label="Таблица пользователей"
      >
        <table>
          <thead>
            <tr>
              {COLUMNS.map((c) => (
                <th
                  key={c.title}
                  className={c.num ? 'num' : undefined}
                  scope="col"
                  aria-sort={sort === c.key ? 'descending' : undefined}
                >
                  {c.key ? (
                    <button
                      type="button"
                      className="sort-button"
                      onClick={() => c.key && setSort(c.key)}
                    >
                      {c.title}
                      {sort === c.key ? (
                        <span aria-hidden="true"> ↓</span>
                      ) : null}
                    </button>
                  ) : (
                    c.title
                  )}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map((u) => (
              <tr key={u.id}>
                <td className="person-cell">
                  <Link to={`/users/${u.id}`}>{u.name}</Link>
                  {u.isSystem ? (
                    <span className="tag" style={{ marginLeft: 6 }}>
                      система
                    </span>
                  ) : null}
                  {u.banned ? (
                    <span className="tag bad" style={{ marginLeft: 6 }}>
                      бан
                    </span>
                  ) : null}
                  {u.pushStatus === 'denied' ? (
                    <span className="tag warn" style={{ marginLeft: 6 }}>
                      пуши запрещены
                    </span>
                  ) : null}
                  {u.pushStatus === 'error' || u.pushStatus === 'no_token' ? (
                    <span className="tag bad" style={{ marginLeft: 6 }}>
                      регистрация сбоит
                    </span>
                  ) : null}
                </td>
                <td className="mono">
                  {u.email ?? <span className="muted">—</span>}
                  {u.email && !u.emailConfirmed ? (
                    <span className="tag warn" style={{ marginLeft: 6 }}>
                      не подтверждена
                    </span>
                  ) : null}
                </td>
                <td className="muted nowrap">{day(u.createdAt)}</td>
                <td className={`nowrap ${u.lastActiveAt ? '' : 'muted'}`}>
                  {ago(u.lastActiveAt)}
                </td>
                <td className="mono">
                  {u.versions.length ? (
                    u.versions.join(', ')
                  ) : (
                    <span className="muted">—</span>
                  )}
                  {u.maxBuild !== null ? (
                    <span className="muted"> +{u.maxBuild}</span>
                  ) : null}
                  {u.devices > 1 ? (
                    <span className="muted"> ({u.devices} устр.)</span>
                  ) : null}
                </td>
                <td className="mono muted nowrap">
                  {u.platforms.join(', ') || '—'}
                </td>
                <td className="mono muted">{u.locales.join(', ') || '—'}</td>
                <td className="num">{u.posts}</td>
                <td className="num">{u.comments}</td>
                <td className="num">{u.connections}</td>
              </tr>
            ))}
            {rows.length === 0 ? (
              <tr>
                <td colSpan={COLUMNS.length} className="empty">
                  {query.trim()
                    ? 'Совпадений нет. Попробуйте другое имя, почту или ID.'
                    : 'Пользователей пока нет.'}
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </section>
    </>
  );
}
