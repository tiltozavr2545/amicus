import type { ErrorInfo, ReactNode } from 'react';
import { Component } from 'react';

type Props = { children: ReactNode };
type State = { error: Error | null };

// The console will keep growing sections, and the cost of an unhandled
// exception in React is a blank white page without a single word: React
// unmounts the whole tree, menu included, and the only way to see what
// happened is devtools. This already happened once out of nowhere (a field
// missing from the response until the API was restarted). The boundary costs
// ten lines and leaves at least the error text and a button on screen.
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
        <button type="button" onClick={() => window.location.reload()}>
          Перезагрузить
        </button>
      </div>
    );
  }
}
