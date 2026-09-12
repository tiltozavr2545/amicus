import { useEffect, useState } from 'react';
import type { NewsDraft, NewsMedia, NewsPost, NewsResponse } from '../../shared/types';
import { useApi } from '../api';
import { Fail, ago, date } from '../components/ui';

const MAX_MEDIA = 20;

async function send(path: string, method: string, body?: unknown): Promise<any> {
  const response = await fetch(`/api${path}`, {
    method,
    headers: body === undefined ? undefined : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const parsed = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((parsed as { error?: string }).error ?? response.statusText);
  return parsed;
}

async function upload(file: File, name = file.name, type = file.type) {
  const query = `name=${encodeURIComponent(name)}&type=${encodeURIComponent(type)}`;
  const response = await fetch(`/api/news/media?${query}`, {
    method: 'POST',
    headers: { 'Content-Type': type },
    body: file,
  });
  const parsed = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error((parsed as { error?: string }).error ?? response.statusText);
  return parsed as { path: string; url: string | null; mediaType: string };
}

// Постер видео снимается прямо в браузере: кадр на первой секунде через
// canvas. Иначе на сервере понадобился бы ffmpeg ради одной картинки, а без
// постера видео в ленте показывать нечем.
//
// Возвращает null, если браузер не смог декодировать файл, — публикация от
// этого не срывается, постер просто не приложится.
function posterFor(file: File): Promise<Blob | null> {
  return new Promise((resolve) => {
    const video = document.createElement('video');
    const url = URL.createObjectURL(file);
    const done = (blob: Blob | null) => {
      URL.revokeObjectURL(url);
      resolve(blob);
    };
    video.muted = true;
    video.playsInline = true;
    video.src = url;
    video.onerror = () => done(null);
    video.onloadeddata = () => {
      video.currentTime = Math.min(1, (video.duration || 1) / 2);
    };
    video.onseeked = () => {
      try {
        const canvas = document.createElement('canvas');
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        const context = canvas.getContext('2d');
        if (!context || !canvas.width) return done(null);
        context.drawImage(video, 0, 0);
        canvas.toBlob((blob) => done(blob), 'image/jpeg', 0.8);
      } catch {
        done(null);
      }
    };
    // Не ждём вечно: битый или экзотический файл не должен подвесить форму.
    setTimeout(() => done(null), 10000);
  });
}

function Preview({ text, media }: { text: string; media: NewsMedia[] }) {
  const shown = media.filter((m) => m.posterUrl ?? m.url);
  return (
    <div className="post-preview">
      <div className="who">Amicus</div>
      <div className="when">{date(new Date().toISOString())}</div>
      {text.trim() ? (
        <div className="body">{text}</div>
      ) : (
        <div className="body muted">…текст поста…</div>
      )}
      {shown.length > 0 ? (
        <div className={`grid ${shown.length === 1 ? 'one' : ''}`}>
          {shown.map((m) => (
            <img key={m.storagePath} src={(m.posterUrl ?? m.url) as string} alt="" />
          ))}
        </div>
      ) : null}
    </div>
  );
}

export function News() {
  const { data, error, loading, reload } = useApi<NewsResponse>('/news');
  const [text, setText] = useState('');
  const [media, setMedia] = useState<NewsMedia[]>([]);
  const [editing, setEditing] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [drafts, setDrafts] = useState<NewsDraft[]>([]);

  useEffect(() => {
    if (data) setDrafts(data.drafts);
  }, [data]);

  if (error) return <Fail message={error} onRetry={reload} />;
  if (!data) return <p className="muted">{loading ? 'Читаю ленту аккаунта…' : ''}</p>;

  async function run(label: string, fn: () => Promise<void>, confirmText?: string) {
    if (confirmText && !window.confirm(confirmText)) return;
    setBusy(label);
    setNotice(null);
    try {
      await fn();
    } catch (e) {
      setNotice((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  function clear() {
    setText('');
    setMedia([]);
    setEditing(null);
  }

  async function addFiles(files: FileList | null) {
    if (!files || files.length === 0) return;
    const room = MAX_MEDIA - media.length;
    if (room <= 0) {
      setNotice(`Больше ${MAX_MEDIA} медиа в пост не поместится`);
      return;
    }
    await run('upload', async () => {
      const added: NewsMedia[] = [];
      for (const file of [...files].slice(0, room)) {
        const uploaded = await upload(file);
        let posterPath: string | null = null;
        let posterUrl: string | null = null;
        if (uploaded.mediaType === 'video') {
          const poster = await posterFor(file);
          if (poster) {
            const posterFile = new File([poster], 'poster.jpg', { type: 'image/jpeg' });
            const up = await upload(posterFile, 'poster.jpg', 'image/jpeg');
            posterPath = up.path;
            posterUrl = up.url;
          }
        }
        added.push({
          mediaType: uploaded.mediaType,
          storagePath: uploaded.path,
          posterPath,
          url: uploaded.url,
          posterUrl,
        });
      }
      setMedia((current) => [...current, ...added]);
    });
  }

  function move(index: number, delta: number) {
    setMedia((current) => {
      const next = [...current];
      const target = index + delta;
      if (target < 0 || target >= next.length) return current;
      [next[index], next[target]] = [next[target], next[index]];
      return next;
    });
  }

  const payload = () => ({
    text,
    media: media.map((m) => ({
      mediaType: m.mediaType,
      storagePath: m.storagePath,
      posterPath: m.posterPath,
    })),
  });

  const publish = () =>
    run('publish', async () => {
      if (editing) {
        await send(`/news/${editing}`, 'PATCH', payload());
      } else {
        await send('/news', 'POST', payload());
      }
      clear();
      reload();
    });

  const saveDrafts = async (next: NewsDraft[]) => {
    setDrafts(next);
    await send('/news/drafts', 'PUT', { drafts: next });
  };

  const keepDraft = () =>
    run('draft', async () => {
      const draft: NewsDraft = {
        id: crypto.randomUUID(),
        text,
        media,
        updatedAt: new Date().toISOString(),
      };
      await saveDrafts([draft, ...drafts]);
      clear();
    });

  return (
    <>
      <div className="page-head">
        <h1>Новости</h1>
        <span className="stamp">
          постов у аккаунта: {data.posts.length} · черновиков: {drafts.length}
        </span>
        <button style={{ marginLeft: 'auto' }} onClick={reload} disabled={loading}>
          {loading ? 'Обновляю…' : 'Обновить'}
        </button>
      </div>

      {notice ? (
        <div className="error" style={{ marginBottom: 12 }}>
          {notice}
        </div>
      ) : null}

      <div className="news-columns">
        <div className="panel">
          <div className="row-actions" style={{ marginBottom: 8 }}>
            <strong>{editing ? 'Правка опубликованного поста' : 'Новый пост'}</strong>
            {editing ? (
              <button onClick={clear} disabled={!!busy}>
                Отменить правку
              </button>
            ) : null}
          </div>
          <textarea
            value={text}
            maxLength={5000}
            placeholder="Пост от лица аккаунта Amicus. Разметки в ленте нет — только текст и пустые строки между абзацами."
            onChange={(e) => setText(e.target.value)}
          />
          <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>
            {text.length} / 5000
          </div>

          <div className="news-thumbs">
            {media.map((m, index) => (
              <div className="news-thumb" key={m.storagePath}>
                <img src={(m.posterUrl ?? m.url) ?? undefined} alt="" />
                {m.mediaType === 'video' ? <span className="kind">видео</span> : null}
                <div className="controls">
                  <button onClick={() => move(index, -1)} disabled={index === 0}>
                    ◀
                  </button>
                  <button
                    onClick={() =>
                      setMedia((current) => current.filter((_, i) => i !== index))
                    }
                  >
                    ✕
                  </button>
                  <button onClick={() => move(index, 1)} disabled={index === media.length - 1}>
                    ▶
                  </button>
                </div>
              </div>
            ))}
          </div>

          <div className="row-actions" style={{ marginTop: 12, flexWrap: 'wrap' }}>
            <label className="muted" style={{ fontSize: 13 }}>
              <input
                type="file"
                multiple
                accept="image/jpeg,image/png,image/webp,image/heic,image/heif,video/mp4,video/quicktime,video/x-m4v,video/3gpp,video/webm,video/x-matroska"
                style={{ display: 'none' }}
                onChange={(e) => {
                  void addFiles(e.target.files);
                  e.target.value = '';
                }}
              />
              <span className="tag" style={{ cursor: 'pointer', padding: '6px 11px' }}>
                {busy === 'upload' ? 'Загружаю…' : `Добавить медиа (${media.length}/${MAX_MEDIA})`}
              </span>
            </label>
            <button onClick={publish} disabled={!!busy}>
              {editing ? 'Сохранить изменения' : 'Опубликовать'}
            </button>
            {editing ? null : (
              <button onClick={keepDraft} disabled={!!busy}>
                В черновики
              </button>
            )}
          </div>
          <p className="muted" style={{ fontSize: 12, marginBottom: 0 }}>
            Публикация уведомлений не рассылает: триггер очереди выходит на
            системном аккаунте (20260820190000). Видео сохраняется с постером —
            кадр снимается здесь же, в браузере.
          </p>
        </div>

        <div>
          <h2 style={{ marginTop: 0 }}>Как это увидят в ленте</h2>
          <Preview text={text} media={media} />

          {drafts.length > 0 ? (
            <>
              <h2>Черновики</h2>
              <div className="panel">
                {drafts.map((d) => (
                  <div className="news-post" key={d.id}>
                    <div className="muted" style={{ fontSize: 12 }}>
                      {ago(d.updatedAt)} · медиа: {d.media.length}
                    </div>
                    <div style={{ whiteSpace: 'pre-wrap', margin: '4px 0 8px' }}>
                      {d.text.slice(0, 200) || <span className="muted">без текста</span>}
                    </div>
                    <div className="row-actions">
                      <button
                        disabled={!!busy}
                        onClick={() => {
                          setText(d.text);
                          setMedia(d.media);
                          setEditing(null);
                        }}
                      >
                        В композер
                      </button>
                      <button
                        disabled={!!busy}
                        onClick={() =>
                          run('drop-draft', () =>
                            saveDrafts(drafts.filter((x) => x.id !== d.id)),
                          )
                        }
                      >
                        Удалить черновик
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </>
          ) : null}
        </div>
      </div>

      <h2>Опубликованное</h2>
      <div className="panel">
        {data.posts.length === 0 ? (
          <p className="empty" style={{ margin: 0 }}>
            У аккаунта ещё нет постов.
          </p>
        ) : (
          data.posts.map((p: NewsPost) => (
            <div className="news-post" key={p.id}>
              <div className="row-actions" style={{ marginBottom: 6 }}>
                <span className="muted" style={{ fontSize: 12 }}>
                  {date(p.createdAt)} · {ago(p.createdAt)}
                </span>
                {p.hidden ? <span className="tag bad">скрыт</span> : null}
                <span className="muted" style={{ fontSize: 12 }}>
                  реакций {p.reactions} · комментариев {p.comments}
                </span>
                <span className="row-actions" style={{ marginLeft: 'auto' }}>
                  <button
                    disabled={!!busy}
                    onClick={() => {
                      setEditing(p.id);
                      setText(p.text ?? '');
                      setMedia(p.media);
                      window.scrollTo(0, 0);
                    }}
                  >
                    Править
                  </button>
                  <button
                    disabled={!!busy}
                    onClick={() =>
                      run(
                        'delete',
                        async () => {
                          await send(`/news/${p.id}`, 'DELETE');
                          if (editing === p.id) clear();
                          reload();
                        },
                        'Удалить пост насовсем? Вместе с комментариями и реакциями под ним.',
                      )
                    }
                  >
                    Удалить
                  </button>
                </span>
              </div>
              <div style={{ whiteSpace: 'pre-wrap' }}>
                {p.text ?? <span className="muted">без текста</span>}
              </div>
              {p.media.length > 0 ? (
                <div className="news-thumbs">
                  {p.media.map((m) => (
                    <div className="news-thumb" key={m.storagePath}>
                      <img src={(m.posterUrl ?? m.url) ?? undefined} alt="" />
                      {m.mediaType === 'video' ? <span className="kind">видео</span> : null}
                    </div>
                  ))}
                </div>
              ) : null}
            </div>
          ))
        )}
      </div>
    </>
  );
}
