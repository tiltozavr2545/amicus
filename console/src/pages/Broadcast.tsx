import { useEffect, useState } from 'react';
import type { BroadcastResponse, BroadcastTarget } from '../../shared/types';
import { get } from '../api';
import { Card, Fail, date } from '../components/ui';

function People({ title, rows, hint }: { title: string; rows: BroadcastTarget[]; hint: string }) {
  if (rows.length === 0) return null;
  return (
    <div className="panel" style={{ marginTop: 12 }}>
      <h2 style={{ margin: '0 0 4px' }}>
        {title} — {rows.length}
      </h2>
      <p className="muted" style={{ fontSize: 12, marginTop: 0 }}>
        {hint}
      </p>
      <table>
        <thead>
          <tr>
            <th className="plain">кто</th>
            <th className="plain num">его build</th>
            <th className="plain">язык</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.userId}>
              <td>{r.name}</td>
              <td className="num mono">
                {r.maxBuild ?? <span className="muted">не сообщал</span>}
              </td>
              <td className="mono muted">{r.locale}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

export function Broadcast() {
  const [build, setBuild] = useState<number | null>(null);
  const [version, setVersion] = useState('');
  const [important, setImportant] = useState(false);
  const [data, setData] = useState<BroadcastResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);

  async function load(target: number | null) {
    try {
      const query = target ? `?build=${target}` : '';
      const next = await get<BroadcastResponse>(`/broadcast${query}`);
      setData(next);
      setError(null);
      if (build === null) {
        setBuild(next.targetBuild);
        setVersion(next.repoVersion?.name ?? '');
      }
    } catch (e) {
      setError((e as Error).message);
    }
  }

  useEffect(() => {
    void load(null);
    // Первая загрузка берёт цель из pubspec; дальше её меняет только поле.
  }, []);

  if (error) return <Fail message={error} onRetry={() => load(build)} />;
  if (!data || build === null) return <p className="muted">Считаю аудиторию…</p>;

  const ahead = data.repoVersion && build > data.repoVersion.build;

  async function send() {
    const kind = important ? 'НАСТОЙЧИВОЕ «важное обновление»' : 'обычное «вышла новая версия»';
    if (
      !window.confirm(
        `Отправить ${kind} уведомление про сборку ${build} — ${data!.willReceive.length} чел.?`,
      )
    ) {
      return;
    }
    setBusy(true);
    setResult(null);
    try {
      const response = await fetch('/api/broadcast/app-update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ build, version: version || null, important }),
      });
      const parsed = await response.json();
      if (!response.ok) throw new Error(parsed.error ?? response.statusText);
      setResult(`Поставлено в очередь: ${parsed.queued}`);
      await load(build);
    } catch (e) {
      setResult(`Не отправилось: ${(e as Error).message}`);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <div className="page-head">
        <h1>Рассылки</h1>
        <span className="stamp">снято {date(data.generatedAt)}</span>
      </div>

      <div className="panel">
        <h2 style={{ marginTop: 0 }}>Уведомление «вышла новая версия»</h2>
        <div className="row-actions" style={{ flexWrap: 'wrap', marginBottom: 10 }}>
          <label className="muted" style={{ fontSize: 13 }}>
            versionCode{' '}
            <input
              type="text"
              style={{ minWidth: 90 }}
              value={build}
              onChange={(e) => {
                const next = Number(e.target.value);
                setBuild(Number.isFinite(next) ? next : 0);
                if (Number.isInteger(next) && next > 0) void load(next);
              }}
            />
          </label>
          <label className="muted" style={{ fontSize: 13 }}>
            versionName{' '}
            <input
              type="text"
              style={{ minWidth: 120 }}
              value={version}
              onChange={(e) => setVersion(e.target.value)}
            />
          </label>
          <label className="muted" style={{ fontSize: 13 }}>
            <input
              type="checkbox"
              checked={important}
              onChange={(e) => setImportant(e.target.checked)}
            />{' '}
            настойчивое
          </label>
          <button onClick={send} disabled={busy || data.willReceive.length === 0}>
            {busy ? 'Отправляю…' : `Отправить ${data.willReceive.length} чел.`}
          </button>
        </div>

        <div className="cards">
          <Card
            label="В репозитории"
            value={data.repoVersion ? `+${data.repoVersion.build}` : '—'}
            hint={data.repoVersion?.name ?? 'pubspec не прочитан'}
          />
          <Card label="Получат" value={data.willReceive.length} hint="отстают от цели" />
          <Card
            label="Уже получали"
            value={data.skippedAlready.length}
            hint="про эту же сборку"
          />
          <Card
            label="Выключили"
            value={data.skippedOptOut.length}
            hint="notify_system_account"
          />
          <Card label="Без устройств" value={data.withoutDevices} hint="не дойдёт ничто" />
        </div>

        {result ? (
          <p style={{ marginBottom: 0, color: 'var(--good)' }}>{result}</p>
        ) : null}

        {ahead ? (
          <p className="warn-note" style={{ fontSize: 12.5, marginBottom: 0 }}>
            Цель выше, чем сборка в <span className="mono">app/pubspec.yaml</span> (
            {data.repoVersion?.build}). Обновляться людям будет некуда, пока эта
            версия не выложена в стор.
          </p>
        ) : null}

        <p className="muted" style={{ fontSize: 12.5, marginBottom: 0 }}>
          Отправку делает <span className="mono">enqueue_app_update_notifications()</span>,
          список выше — её же отбор, посчитанный здесь заранее: отстающим считается
          тот, у кого максимум <span className="mono">app_build</span> по всем
          устройствам ниже цели. Повторный вызов с той же сборкой безопасен —
          про одну сборку человек получит ровно одно уведомление, и обычное с
          настойчивым не сложатся.
        </p>
        {important ? (
          <p className="warn-note" style={{ fontSize: 12.5, marginBottom: 0 }}>
            Настойчивый вид стоит ставить редко и только когда это правда: без
            обновления старый клиент показывает не то — или не работает вовсе.
            Так было дважды за всю историю. Если размечать важным каждый релиз,
            к третьему разу слово перестанет что-либо значить.
          </p>
        ) : null}
      </div>

      <People
        title="Получат уведомление"
        rows={data.willReceive}
        hint="Отстают от целевой сборки, уведомления системного аккаунта не выключали, про эту сборку им ещё не писали."
      />
      <People
        title="Пропущены: уже получали"
        rows={data.skippedAlready}
        hint="Про эту сборку уведомление уже лежало в очереди — защита от повтора внутри функции отсеет их сама."
      />
      <People
        title="Пропущены: выключили уведомления аккаунта"
        rows={data.skippedOptOut}
        hint="Сняли notify_system_account в настройках. Это их выбор, и функция его уважает."
      />

      <h2>Что рассылалось раньше</h2>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain num">build</th>
              <th className="plain">вид</th>
              <th className="plain num">людей</th>
            </tr>
          </thead>
          <tbody>
            {data.history.map((h) => (
              <tr key={`${h.build}-${h.kind}`}>
                <td className="num mono">{h.build}</td>
                <td className="mono">{h.kind}</td>
                <td className="num">{h.users}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
          Это строки очереди, а не доставленные пуши: до человека без устройства
          строка тоже доходит и помечается отправленной.
        </p>
      </div>
    </>
  );
}
