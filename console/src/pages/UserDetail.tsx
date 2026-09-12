import { useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { UserDetailResponse } from '../../shared/types';
import { useApi } from '../api';
import { Card, Fail, ago, date } from '../components/ui';

const PUSH_STATUS: Record<string, string> = {
  granted: 'разрешил, токен записан',
  denied: 'отказал в разрешении',
  no_token: 'разрешил, но FCM не выдал токен',
  error: 'запись токена падает с ошибкой',
};

// Виды, которые осмысленно послать одному человеку руками. Событийных здесь
// нет намеренно: «у вас новый комментарий» там, где его не было, — враньё
// голосом приложения.
const MANUAL_KINDS = [
  {
    kind: 'app_update',
    label: 'Обновитесь',
    needsBuild: true,
    hint: 'Обычное «вышла новая версия». Не уйдёт, если человек выключил уведомления системного аккаунта или уже получал про эту сборку.',
  },
  {
    kind: 'app_update_important',
    label: 'Важное обновление',
    needsBuild: true,
    hint: 'Настойчивый текст. Только когда без обновления старый клиент показывает не то или не работает вовсе.',
  },
  {
    kind: 'moderation_notice',
    label: 'Сообщение модерации',
    needsBuild: false,
    hint: 'Личное сообщение о его материале. Настройкой не выключается — как заявки в знакомые. Приписка необязательна и НЕ переводится.',
  },
];

const COUNT_TITLES: Record<string, string> = {
  posts: 'Посты',
  comments: 'Комментарии',
  reactions: 'Реакции',
  connections: 'Знакомства',
  rooms: 'Комнаты',
  roomMessages: 'Сообщения',
  profilePhotos: 'Фото профиля',
  invites: 'Инвайты',
  blockedBy: 'Заблокировали его',
  mutedBy: 'Замьютили его',
  favoritedBy: 'В избранном у',
};

export function UserDetail() {
  const { id } = useParams();
  const { data, error, loading, reload } = useApi<UserDetailResponse>(`/users/${id}`);
  const [kind, setKind] = useState(MANUAL_KINDS[0].kind);
  const [note, setNote] = useState('');
  const [build, setBuild] = useState('');
  const [sending, setSending] = useState(false);
  const [result, setResult] = useState<string | null>(null);

  const spec = MANUAL_KINDS.find((k) => k.kind === kind)!;

  async function notify() {
    setSending(true);
    setResult(null);
    try {
      const response = await fetch(`/api/users/${id}/notify`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          kind,
          note,
          build: spec.needsBuild ? Number(build) : undefined,
          version: null,
        }),
      });
      const parsed = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(parsed.error ?? response.statusText);
      setResult('Поставлено в очередь');
      setNote('');
      reload();
    } catch (e) {
      setResult((e as Error).message);
    } finally {
      setSending(false);
    }
  }

  if (error) return <Fail message={error} onRetry={reload} />;
  if (!data) return <p className="muted">{loading ? 'Читаю…' : ''}</p>;

  const u = data.user;
  return (
    <>
      <div className="page-head">
        <h1>{u.name}</h1>
        {u.isSystem ? <span className="tag">системный аккаунт</span> : null}
        {u.banned ? <span className="tag bad">бан</span> : null}
        <span className="stamp">
          <Link to="/users">← к списку</Link>
        </span>
        <button style={{ marginLeft: 'auto' }} onClick={reload} disabled={loading}>
          {loading ? 'Обновляю…' : 'Обновить'}
        </button>
      </div>

      <div className="panel" style={{ marginBottom: 16 }}>
        <table>
          <tbody>
            <tr>
              <td className="muted">id</td>
              <td className="mono">{u.id}</td>
            </tr>
            <tr>
              <td className="muted">почта</td>
              <td className="mono">
                {u.email ?? '—'}{' '}
                {u.email ? (
                  <span className={`tag ${u.emailConfirmed ? 'good' : 'warn'}`}>
                    {u.emailConfirmed ? 'подтверждена' : 'не подтверждена'}
                  </span>
                ) : null}
              </td>
            </tr>
            <tr>
              <td className="muted">регистрация</td>
              <td>{date(u.createdAt)}</td>
            </tr>
            <tr>
              <td className="muted">последний вход</td>
              <td>{date(u.lastSignInAt)}</td>
            </tr>
            <tr>
              <td className="muted">был в приложении</td>
              <td>{ago(u.lastActiveAt)}</td>
            </tr>
            <tr>
              <td className="muted">регистрация пушей</td>
              <td>
                {u.pushStatus === null ? (
                  <span className="muted">
                    не сообщал — открывал приложение до версии, которая это умеет
                  </span>
                ) : (
                  <>
                    <span
                      className={`tag ${
                        u.pushStatus === 'granted'
                          ? 'good'
                          : u.pushStatus === 'denied'
                            ? 'warn'
                            : 'bad'
                      }`}
                    >
                      {PUSH_STATUS[u.pushStatus] ?? u.pushStatus}
                    </span>{' '}
                    <span className="muted">{ago(u.pushStatusAt)}</span>
                    {u.pushStatusDetail ? (
                      <div className="mono muted" style={{ marginTop: 4 }}>
                        {u.pushStatusDetail}
                      </div>
                    ) : null}
                  </>
                )}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <div className="cards">
        {Object.entries(data.counts).map(([key, value]) => (
          <Card key={key} label={COUNT_TITLES[key] ?? key} value={value} />
        ))}
      </div>

      <h2>Отправить уведомление</h2>
      <div className="panel">
        <div className="row-actions" style={{ flexWrap: 'wrap', marginBottom: 8 }}>
          <select value={kind} onChange={(e) => setKind(e.target.value)} disabled={sending}>
            {MANUAL_KINDS.map((k) => (
              <option key={k.kind} value={k.kind}>
                {k.label}
              </option>
            ))}
          </select>
          {spec.needsBuild ? (
            <input
              type="text"
              style={{ minWidth: 110 }}
              placeholder="versionCode"
              value={build}
              disabled={sending}
              onChange={(e) => setBuild(e.target.value)}
            />
          ) : (
            <input
              type="text"
              style={{ flex: 1, minWidth: 260 }}
              placeholder="Приписка (необязательно) — она НЕ переводится"
              value={note}
              disabled={sending}
              onChange={(e) => setNote(e.target.value)}
            />
          )}
          <button onClick={notify} disabled={sending || (spec.needsBuild && !build)}>
            {sending ? 'Отправляю…' : 'Отправить'}
          </button>
        </div>
        <p className="muted" style={{ fontSize: 12.5, margin: 0 }}>
          {spec.hint}
        </p>
        {u.devices === 0 ? (
          <p className="warn-note" style={{ fontSize: 12.5, marginBottom: 0 }}>
            У него нет ни одного устройства — строка встанет в очередь и будет
            помечена отправленной, но никуда не придёт.
          </p>
        ) : null}
        {result ? (
          <p style={{ fontSize: 12.5, marginBottom: 0, color: 'var(--accent)' }}>{result}</p>
        ) : null}
      </div>

      <h2>Устройства</h2>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain">токен</th>
              <th className="plain">версия</th>
              <th className="plain num">build</th>
              <th className="plain">платформа</th>
              <th className="plain">ОС</th>
              <th className="plain">язык</th>
              <th className="plain">заведено</th>
              <th className="plain">обновлено</th>
            </tr>
          </thead>
          <tbody>
            {data.devices.map((d) => (
              <tr key={d.tokenTail}>
                <td className="mono muted">…{d.tokenTail}</td>
                <td className="mono">{d.appVersion ?? <span className="muted">не сообщена</span>}</td>
                <td className="num mono">{d.appBuild ?? '—'}</td>
                <td className="mono">{d.platform ?? <span className="muted">—</span>}</td>
                <td className="mono">{d.osVersion ?? <span className="muted">—</span>}</td>
                <td className="mono">{d.locale}</td>
                <td className="muted">{date(d.createdAt)}</td>
                <td>{ago(d.updatedAt)}</td>
              </tr>
            ))}
            {data.devices.length === 0 ? (
              <tr>
                <td colSpan={8} className="empty">
                  Устройств нет — пуши до него не дойдут.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>

      <h2>Уведомления</h2>
      <div className="grid-2">
        <div className="panel">
          <div className="muted" style={{ fontSize: 12, marginBottom: 8 }}>
            Настройки. Пусто — строки нет, значит включено всё.
          </div>
          <table>
            <tbody>
              {data.preferences === null ? (
                <tr>
                  <td className="muted">всё включено (по умолчанию)</td>
                </tr>
              ) : (
                Object.entries(data.preferences).map(([key, on]) => (
                  <tr key={key}>
                    <td className="mono">{key}</td>
                    <td>
                      <span className={`tag ${on ? 'good' : 'bad'}`}>{on ? 'вкл' : 'выкл'}</span>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
        <div className="panel">
          <div className="muted" style={{ fontSize: 12, marginBottom: 8 }}>
            Последние 20 строк очереди.
          </div>
          <table>
            <tbody>
              {data.recentNotifications.map((n, i) => (
                <tr key={`${n.kind}-${n.createdAt}-${i}`}>
                  <td className="mono">{n.kind}</td>
                  <td className="muted">{date(n.createdAt)}</td>
                  <td>
                    <span className={`tag ${n.sentAt ? 'good' : 'warn'}`}>
                      {n.sentAt ? 'ушло' : 'в очереди'}
                    </span>
                  </td>
                </tr>
              ))}
              {data.recentNotifications.length === 0 ? (
                <tr>
                  <td className="empty">Ничего не отправлялось.</td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      </div>

      <h2>Последние посты</h2>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain">когда</th>
              <th className="plain">видимость</th>
              <th className="plain num">медиа</th>
              <th className="plain">текст</th>
            </tr>
          </thead>
          <tbody>
            {data.recentPosts.map((p) => (
              <tr key={p.id}>
                <td className="muted">{date(p.createdAt)}</td>
                <td className="mono">{p.visibility ?? '—'}</td>
                <td className="num">{p.media}</td>
                <td>{p.text ? p.text.slice(0, 160) : <span className="muted">без текста</span>}</td>
              </tr>
            ))}
            {data.recentPosts.length === 0 ? (
              <tr>
                <td colSpan={4} className="empty">
                  Постов нет.
                </td>
              </tr>
            ) : null}
          </tbody>
        </table>
      </div>
    </>
  );
}
