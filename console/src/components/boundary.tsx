import { Component } from 'react';
import type { ErrorInfo, ReactNode } from 'react';

type Props = { children: ReactNode };
type State = { error: Error | null };

// Консоль будет обрастать разделами, и цена необработанного исключения в
// React — пустая белая страница без единого слова: React снимает всё дерево,
// включая меню, и понять, что случилось, можно только в devtools. Один раз
// это уже произошло на ровном месте (поле, которого не было в ответе, пока
// не перезапустился API). Граница стоит десяти строк и оставляет на экране
// хотя бы текст ошибки и кнопку.
export class Boundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('[console]', error, info.componentStack);
  }

  render() {
    const { error } = this.state;
    if (!error) return this.props.children;
    return (
      <div className="error">
        <div style={{ marginBottom: 8 }}>
          Экран не отрисовался: {error.message}
        </div>
        <div className="muted" style={{ fontSize: 12, marginBottom: 10 }}>
          Если это случилось сразу после правки кода — скорее всего в состоянии
          остался ответ старого формата, и лечится перезагрузкой страницы.
        </div>
        <button onClick={() => window.location.reload()}>Перезагрузить</button>
      </div>
    );
  }
}
