import type { OverviewResponse } from '../../shared/types';
import { useApi } from '../api';
import { Bars, Card, Fail, date } from '../components/ui';

export function Overview() {
  const { data, error, loading, reload } = useApi<OverviewResponse>('/overview');

  if (error) return <Fail message={error} onRetry={reload} />;
  if (!data) return <p className="muted">{loading ? 'Считаю…' : ''}</p>;

  const t = data.totals;
  // Установка не может сообщить сборку, которой нет в pubspec, — если
  // сообщает, номер подняли по дороге в стор, и знать об этом полезнее, чем
  // молча показывать её как «свежую».
  const ahead =
    data.repoVersion !== null &&
    data.latestBuild !== null &&
    data.latestBuild > data.repoVersion.build;
  return (
    <>
      <div className="page-head">
        <h1>Обзор</h1>
        <span className="stamp">снято {date(data.generatedAt)}</span>
        <button onClick={reload} disabled={loading}>
          {loading ? 'Обновляю…' : 'Обновить'}
        </button>
      </div>

      <div className="cards">
        <Card label="Пользователи" value={t.users} hint={`${data.activity.neverActive} ни разу не заходили`} />
        <Card label="Активны за сутки" value={data.activity.dau} hint={`неделя ${data.activity.wau} · месяц ${data.activity.mau}`} />
        <Card label="Посты" value={t.posts} />
        <Card label="Комментарии" value={t.comments} />
        <Card label="Реакции" value={t.reactions} />
        <Card label="Знакомства" value={t.connections} />
        <Card label="Комнаты" value={t.rooms} hint={`${t.roomMessages} сообщений`} />
        <Card label="Устройства" value={t.devices} />
      </div>

      <div className="grid-2" style={{ marginTop: 18 }}>
        <div className="panel">
          <h2 style={{ margin: '0 0 4px' }}>Регистрации, 30 дней</h2>
          <Bars points={data.signups} />
          <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
            всего за период: {data.signups.reduce((s, p) => s + p.count, 0)}
          </div>
        </div>
        <div className="panel">
          <h2 style={{ margin: '0 0 4px' }}>Посты, 30 дней</h2>
          <Bars points={data.posts} />
          <div className="muted" style={{ fontSize: 12, marginTop: 6 }}>
            всего за период: {data.posts.reduce((s, p) => s + p.count, 0)}
          </div>
        </div>
      </div>

      <h2>Версии приложения</h2>
      <div className="cards" style={{ marginBottom: 12 }}>
        <Card
          label="В репозитории"
          value={data.repoVersion ? `+${data.repoVersion.build}` : '—'}
          hint={data.repoVersion ? data.repoVersion.name : 'pubspec.yaml не прочитан'}
        />
        <Card
          label="Максимум у устройств"
          value={data.latestBuild ?? '—'}
          hint={
            ahead ? (
              <span className="tag warn">выше pubspec</span>
            ) : (
              'по тому, что сообщили клиенты'
            )
          }
        />
        <Card label="На максимальной" value={data.usersOnLatest} hint="людей, не установок" />
        <Card label="Отстали" value={data.usersBehind} hint="максимум build ниже" />
        <Card
          label="Версия не сообщена"
          value={data.usersUnknownBuild}
          hint="устройство есть, build пустой"
        />
        <Card
          label="Без устройств"
          value={data.usersWithoutDevices}
          hint="пуш не дойдёт вовсе"
        />
      </div>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain">Версия</th>
              <th className="plain num">build</th>
              <th className="plain num">установок</th>
              <th className="plain num">людей</th>
            </tr>
          </thead>
          <tbody>
            {data.versions.map((v) => (
              <tr key={`${v.version}+${v.build}`}>
                <td className="mono">{v.version ?? <span className="muted">не сообщена</span>}</td>
                <td className="num mono">{v.build ?? '—'}</td>
                <td className="num">{v.installs}</td>
                <td className="num">{v.users}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
          Версия — свойство установки, а не человека: телефон и планшет одного
          пользователя бывают на разных сборках. Решения принимаются по build.
          {ahead ? (
            <>
              {' '}Устройства сообщают build выше, чем в{' '}
              <span className="mono">app/pubspec.yaml</span> (
              {data.repoVersion?.build} → {data.latestBuild}): номер сборки подняли
              где-то между репозиторием и стором.
            </>
          ) : null}
        </p>
      </div>

      <div className="grid-2" style={{ marginTop: 18 }}>
        <div className="panel">
          <h2 style={{ margin: '0 0 8px' }}>Платформы и языки</h2>
          <table>
            <thead>
              <tr>
                <th className="plain">платформа</th>
                <th className="plain num">установок</th>
                <th className="plain num">людей</th>
              </tr>
            </thead>
            <tbody>
              {data.platforms.map((p) => (
                <tr key={p.platform}>
                  <td className="mono">{p.platform}</td>
                  <td className="num">{p.installs}</td>
                  <td className="num">{p.users}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <table style={{ marginTop: 10 }}>
            <thead>
              <tr>
                <th className="plain">язык</th>
                <th className="plain num">установок</th>
              </tr>
            </thead>
            <tbody>
              {data.locales.map((l) => (
                <tr key={l.locale}>
                  <td className="mono">{l.locale}</td>
                  <td className="num">{l.installs}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="panel">
          <h2 style={{ margin: '0 0 8px' }}>Очередь уведомлений</h2>
          <div className="cards" style={{ gridTemplateColumns: '1fr 1fr' }}>
            <Card label="Не отправлено" value={data.outbox.pending} />
            <Card label="Ушло за сутки" value={data.outbox.sentLast24h} />
          </div>
          <table style={{ marginTop: 10 }}>
            <thead>
              <tr>
                <th className="plain">вид, 7 дней</th>
                <th className="plain num">штук</th>
              </tr>
            </thead>
            <tbody>
              {data.outbox.byKindLast7d.length === 0 ? (
                <tr>
                  <td colSpan={2} className="muted">за неделю пусто</td>
                </tr>
              ) : (
                data.outbox.byKindLast7d.map((k) => (
                  <tr key={k.kind}>
                    <td className="mono">{k.kind}</td>
                    <td className="num">{k.count}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </div>

      <h2>Возраст пуш-токенов</h2>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain">не выходили на связь</th>
              <th className="plain num">токенов</th>
              <th className="plain num">людей</th>
            </tr>
          </thead>
          <tbody>
            {data.tokenAges.map((a) => (
              <tr key={a.bucket}>
                <td>{a.bucket}</td>
                <td className="num">{a.tokens}</td>
                <td className="num">{a.users}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
          Мёртвые строки убирает <span className="mono">send-push</span>, но
          только когда FCM отвечает <span className="mono">UNREGISTERED</span> —
          то есть лишь у тех, кому что-то отправляют. Отдельного джоба по
          возрасту нет намеренно: он бил бы по аудитории{' '}
          <span className="mono">inactive-week-nudge</span>, для которой пуш —
          единственный способ вернуться. Заводить его есть смысл, если тут
          начнёт копиться хвост в 270+ дней.
        </p>
      </div>

      <h2>Почему не доходят пуши</h2>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain">состояние</th>
              <th className="plain num">людей</th>
            </tr>
          </thead>
          <tbody>
            {data.pushReachability.map((r) => (
              <tr key={r.state}>
                <td>{r.state}</td>
                <td className="num">{r.users}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
          Раньше здесь был только счётчик «без устройств», который валил в одну
          кучу отказ в разрешении, сбой регистрации и «просто не открывал
          приложение». Строку пишет сам клиент на каждый запуск, поэтому
          «не сообщал» будет таять по мере того, как люди обновятся.
        </p>
      </div>

      <h2>Отключённые уведомления</h2>
      <div className="panel">
        <table>
          <thead>
            <tr>
              <th className="plain">настройка</th>
              <th className="plain num">выключили</th>
            </tr>
          </thead>
          <tbody>
            {data.optOuts.map((o) => (
              <tr key={o.setting}>
                <td className="mono">{o.setting}</td>
                <td className="num">{o.users}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
          Считается только явный <span className="mono">false</span>: отсутствие
          строки в <span className="mono">notification_preferences</span> значит
          «всё включено».
        </p>
      </div>
    </>
  );
}
