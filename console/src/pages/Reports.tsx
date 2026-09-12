import { useState } from 'react';
import type { ReactNode } from 'react';
import type { ReportMedia, ReportRow, ReportsResponse } from '../../shared/types';
import { useApi } from '../api';
import { Fail, ago, date } from '../components/ui';

const REASONS: Record<string, string> = {
  spam: 'Спам или реклама',
  harassment: 'Травля или оскорбления',
  hate: 'Ненависть и вражда',
  violence: 'Насилие или угрозы',
  sexual: 'Откровенный контент',
  illegal: 'Противозаконное',
  other: 'Другое',
};

const KINDS: Record<string, string> = {
  post: 'пост',
  comment: 'комментарий',
  room_message: 'сообщение в комнате',
  user: 'пользователь',
};

async function post(path: string, body: unknown): Promise<void> {
  const response = await fetch(`/api${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    const parsed = await response.json().catch(() => ({}));
    throw new Error((parsed as { error?: string }).error ?? response.statusText);
  }
}


/** С заглавной — эти подписи начинают предложение. */
function cap(value: string): string {
  return value.charAt(0).toUpperCase() + value.slice(1);
}

/** Существительное объекта в винительном падеже — для описаний действий. */
const ACCUSATIVE: Record<string, string> = {
  post: 'пост',
  comment: 'комментарий',
  room_message: 'сообщение',
  user: 'пользователя',
};

function Action({
  label,
  description,
  onClick,
  disabled,
  danger,
}: {
  label: string;
  description: ReactNode;
  onClick: () => void;
  disabled: boolean;
  danger?: boolean;
}) {
  return (
    <div className="action">
      <button className={danger ? 'danger' : undefined} disabled={disabled} onClick={onClick}>
        {label}
      </button>
      <p>{description}</p>
    </div>
  );
}

function MediaStrip({ media }: { media: ReportMedia[] }) {
  if (media.length === 0) return null;
  return (
    <div className="media-strip">
      {media.map((m) => {
        // У видео показываем постер: проигрывать в карточке нечего, а по
        // ссылке файл открывается в отдельной вкладке как есть.
        const src = m.kind === 'video' ? m.posterUrl ?? m.url : m.url;
        if (!src) {
          return (
            <div className="media-missing" key={m.path} title={m.path}>
              файл недоступен
            </div>
          );
        }
        return (
          <a key={m.path} href={m.url ?? src} target="_blank" rel="noreferrer" title={m.path}>
            <img src={src} alt="" />
            {m.kind === 'video' ? <span className="badge">видео</span> : null}
          </a>
        );
      })}
    </div>
  );
}

function Card({ report, onDone }: { report: ReportRow; onDone: () => void }) {
  const [note, setNote] = useState('');
  const [notify, setNotify] = useState(true);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [banDays, setBanDays] = useState(7);

  const isContent = report.targetKind !== 'user';

  async function run(label: string, fn: () => Promise<void>, confirmText?: string) {
    if (confirmText && !window.confirm(confirmText)) return;
    setBusy(label);
    setError(null);
    try {
      await fn();
      onDone();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  const content = (action: 'hide' | 'unhide' | 'delete') =>
    post('/moderation/content', {
      kind: report.targetKind,
      targetId: report.targetId,
      action,
      notifyAuthor: notify && action !== 'unhide',
      note,
    });

  const resolve = (status: 'resolved' | 'rejected') =>
    post(`/reports/${report.id}/resolve`, {
      status,
      resolution: status === 'resolved' ? 'Меры приняты' : 'Нарушения не найдено',
      notifyReporter: notify,
      note,
    });

  const writeToAuthor = () =>
    post(`/users/${report.targetAuthorId}/notify`, {
      kind: 'moderation_notice',
      note,
    });

  const ban = (mode: 'write' | 'auth' | 'none', days?: number) =>
    post('/moderation/ban', {
      userId: report.targetAuthorId,
      mode,
      days,
      notify,
      note,
    });

  return (
    <div className="panel" style={{ marginBottom: 12 }}>
      <div className="row-actions" style={{ marginBottom: 8, flexWrap: 'wrap' }}>
        <strong>{KINDS[report.targetKind] ?? report.targetKind}</strong>
        <span className="tag warn">{REASONS[report.reason] ?? report.reason}</span>
        {report.reportsOnTarget > 1 ? (
          <span className="tag bad">жалоб на объект: {report.reportsOnTarget}</span>
        ) : null}
        {report.targetHidden ? <span className="tag">уже скрыт</span> : null}
        {!report.targetExists ? <span className="tag">объекта уже нет</span> : null}
        {report.targetAuthorBanned ? <span className="tag bad">вход забанен</span> : null}
        {report.status !== 'open' ? (
          <span className="tag good">{report.status === 'resolved' ? 'разобрано' : 'отклонено'}</span>
        ) : null}
        <span className="muted" style={{ marginLeft: 'auto', fontSize: 12 }}>
          {ago(report.createdAt)} · {date(report.createdAt)}
        </span>
      </div>

      <table style={{ marginBottom: 10 }}>
        <tbody>
          <tr>
            <td className="muted" style={{ width: 150 }}>автор</td>
            <td>{report.targetAuthorName ?? '—'}</td>
          </tr>
          <tr>
            <td className="muted">пожаловался</td>
            <td>
              {report.reporterName}
              {report.reporterTotal > 1 ? (
                <span className="muted" style={{ fontSize: 12 }}>
                  {' '}· жалоб за всё время: {report.reporterTotal}
                  {report.reporterRejected > 0
                    ? `, отклонено ${report.reporterRejected}`
                    : ''}
                </span>
              ) : null}
              {report.reporterRejected >= 3 ? (
                <span className="tag warn" style={{ marginLeft: 6 }}>
                  часто жалуется впустую
                </span>
              ) : null}
            </td>
          </tr>
          {report.targetSnapshot ? (
            <tr>
              <td className="muted">текст на момент жалобы</td>
              <td style={{ whiteSpace: 'pre-wrap' }}>{report.targetSnapshot}</td>
            </tr>
          ) : null}
          {report.note ? (
            <tr>
              <td className="muted">что написал жалобщик</td>
              <td style={{ whiteSpace: 'pre-wrap' }}>{report.note}</td>
            </tr>
          ) : null}
        </tbody>
      </table>

      <MediaStrip media={report.media} />

      <div className="row-actions" style={{ marginBottom: 8, flexWrap: 'wrap' }}>
        <input
          type="text"
          style={{ flex: 1, minWidth: 280 }}
          placeholder="Приписка в уведомление (необязательно) — она НЕ переводится"
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
        <label className="muted" style={{ fontSize: 12 }}>
          <input
            type="checkbox"
            checked={notify}
            onChange={(e) => setNotify(e.target.checked)}
          />{' '}
          уведомить
        </label>
      </div>

      <div>
        {isContent && report.targetExists && !report.targetHidden ? (
          <Action
            label="Скрыть"
            disabled={!!busy}
            onClick={() => run('hide', () => content('hide'))}
            description={
              <>
                {cap(ACCUSATIVE[report.targetKind] ?? 'объект')} исчезнет у всех, включая
                самого автора, вместе с прикреплёнными файлами. Строка и файлы
                остаются на месте — действие обратимо кнопкой «Вернуть».
                {notify ? ' Автору уйдёт уведомление.' : ' Уведомление не уйдёт — галочка снята.'}
              </>
            }
          />
        ) : null}

        {isContent && report.targetExists && report.targetHidden ? (
          <Action
            label="Вернуть"
            disabled={!!busy}
            onClick={() => run('unhide', () => content('unhide'))}
            description="Снимет скрытие: объект снова увидят те, кто видел его раньше. Уведомление автору не отправляется в любом случае."
          />
        ) : null}

        {isContent && report.targetExists ? (
          <Action
            label="Удалить"
            danger
            disabled={!!busy}
            onClick={() => run('delete', () => content('delete'), 'Удалить безвозвратно?')}
            description={
              report.targetKind === 'post' ? (
                <>
                  Строка сносится насовсем, вместе с комментариями и реакциями под
                  ней. Файлы из бакета вынесет уборщик в течение суток.{' '}
                  <span className="warn-note">Отменить нельзя.</span>
                </>
              ) : (
                <>
                  На месте останется заглушка «удалено» — без текста и файлов, но
                  строка сохранится, иначе оборвётся ветка ответов на неё. Так же
                  удаляет и сам автор из приложения.{' '}
                  <span className="warn-note">Отменить нельзя.</span>
                </>
              )
            }
          />
        ) : null}

        {report.targetAuthorId ? (
          <Action
            label="Написать автору"
            disabled={!!busy}
            onClick={() => run('write', writeToAuthor)}
            description={
              <>
                Отправит ему сообщение модерации и <b>больше ничего</b>: контент
                останется на месте, жалоба — в очереди. Для предупреждения, когда
                убирать нечего, а сказать есть что. Приписка выше уходит в текст;
                без неё придёт общая формулировка. Настройкой уведомлений это не
                выключается — сообщение личное, про его же материал.
              </>
            }
          />
        ) : null}

        {report.targetAuthorId ? (
          <>
            <div className="action">
              <button
                disabled={!!busy}
                onClick={() =>
                  run('ban', () => ban('write', banDays), `Запретить писать на ${banDays} дн.?`)
                }
              >
                Запретить писать
              </button>
              <p>
                Автор не сможет публиковать посты, комментировать, писать в
                комнатах, ставить реакции, звать в знакомые и добавлять фото в
                профиль. Читать ленту и заходить — сможет; при попытке написать
                увидит дату окончания. Срок:{' '}
                <select
                  value={banDays}
                  disabled={!!busy}
                  onChange={(e) => setBanDays(Number(e.target.value))}
                >
                  <option value={1}>1 день</option>
                  <option value={3}>3 дня</option>
                  <option value={7}>7 дней</option>
                  <option value={30}>30 дней</option>
                  <option value={365}>год</option>
                </select>{' '}
                Снимается досрочно кнопкой ниже.
              </p>
            </div>

            <Action
              label="Забанить вход"
              danger
              disabled={!!busy}
              onClick={() =>
                run('banauth', () => ban('auth'), 'Закрыть вход в аккаунт на 10 лет?')
              }
              description={
                <>
                  Самое жёсткое: аккаунт вообще не сможет войти — ни прочитать свою
                  переписку, ни увидеть объяснение, только ошибка входа. Данные не
                  удаляются. Снимается кнопкой ниже.
                </>
              }
            />

            <Action
              label="Снять ограничения"
              disabled={!!busy}
              onClick={() => run('unban', () => ban('none'))}
              description="Снимает разом и запрет писать, и бан входа. Контента не касается: скрытое останется скрытым."
            />
          </>
        ) : null}

        {report.status === 'open' ? (
          <>
            <Action
              label="Закрыть жалобу"
              disabled={!!busy}
              onClick={() => run('resolved', () => resolve('resolved'))}
              description={
                <>
                  Исход «нарушение было, меры приняты». Уберёт жалобу из очереди;{' '}
                  <b>самого контента не трогает</b> — скрывать или удалять надо
                  отдельно, до или после.
                  {notify
                    ? ' Жалобщику уйдёт «рассмотрена, меры приняты».'
                    : ' Жалобщик ничего не узнает — галочка снята.'}
                </>
              }
            />
            <Action
              label="Отклонить"
              disabled={!!busy}
              onClick={() => run('rejected', () => resolve('rejected'))}
              description={
                <>
                  Исход «нарушения нет». С контентом делает ровно то же, что и
                  кнопка слева, — <b>ничего</b>. Разница в двух вещах: жалобщику
                  уходит другой текст
                  {notify ? ' («рассмотрели, нарушения не нашли»)' : ''}, и
                  отклонённые жалобы копятся в его историю — по ней видно того,
                  кто жалуется впустую. Отдельной кнопки «написать жалобщику» нет
                  намеренно: оба готовых текста для него описывают ИСХОД разбора,
                  и врозь с ним это было бы сообщение о решении, которого ещё не
                  приняли.
                </>
              }
            />
          </>
        ) : null}
      </div>

      {error ? (
        <p style={{ color: 'var(--bad)', fontSize: 12, marginBottom: 0 }}>{error}</p>
      ) : null}
    </div>
  );
}

export function Reports() {
  const [showAll, setShowAll] = useState(false);
  const { data, error, loading, reload } = useApi<ReportsResponse>(
    showAll ? '/reports?status=all' : '/reports',
  );

  if (error) return <Fail message={error} onRetry={reload} />;
  if (!data) return <p className="muted">{loading ? 'Читаю очередь…' : ''}</p>;

  return (
    <>
      <div className="page-head">
        <h1>Жалобы</h1>
        <span className="stamp">
          открытых {data.open} · снято {date(data.generatedAt)}
        </span>
        <div className="row-actions" style={{ marginLeft: 'auto' }}>
          <button onClick={() => setShowAll((v) => !v)}>
            {showAll ? 'Только открытые' : 'Показать разобранные'}
          </button>
          <button onClick={reload} disabled={loading}>
            {loading ? 'Обновляю…' : 'Обновить'}
          </button>
        </div>
      </div>

      {data.reports.length === 0 ? (
        <div className="panel">
          <p className="empty" style={{ margin: 0 }}>
            {showAll ? 'Жалоб не было ни одной.' : 'Разбирать нечего — открытых жалоб нет.'}
          </p>
        </div>
      ) : (
        data.reports.map((r) => <Card key={r.id} report={r} onDone={reload} />)
      )}
    </>
  );
}
