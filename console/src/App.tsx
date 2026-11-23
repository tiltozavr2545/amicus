import { useEffect } from 'react';
import {
  Navigate,
  NavLink,
  Route,
  Routes,
  useLocation,
} from 'react-router-dom';
import { Boundary } from './components/boundary';
import { Broadcast } from './pages/Broadcast';
import { News } from './pages/News';
import { Overview } from './pages/Overview';
import { Reports } from './pages/Reports';
import { UserDetail } from './pages/UserDetail';
import { Users } from './pages/Users';

// The router doesn't reset scroll on its own: navigating from a list scrolled
// down into a detail card landed in the middle of the card.
function ScrollToTop() {
  const { pathname } = useLocation();
  // biome-ignore lint/correctness/useExhaustiveDependencies: pathname is the re-run trigger, not a value the effect body reads.
  useEffect(() => {
    window.scrollTo(0, 0);
  }, [pathname]);
  return null;
}

export function App() {
  return (
    <div className="layout">
      <button
        className="skip-link"
        type="button"
        onClick={() => document.getElementById('workspace')?.focus()}
      >
        К содержимому
      </button>
      <aside className="sidebar">
        <div className="brand-lockup">
          <span className="brand-icon" aria-hidden="true" />
          <div>
            <p className="brand">Amicus</p>
            <p className="brand-sub">Админ-консоль</p>
          </div>
        </div>
        <nav className="nav" aria-label="Разделы консоли">
          <div className="nav-group">
            <NavLink to="/overview">Обзор</NavLink>
            <NavLink to="/users">Пользователи</NavLink>
            <NavLink to="/reports">Жалобы</NavLink>
          </div>
          <div className="nav-group">
            <NavLink to="/news">Новости</NavLink>
            <NavLink to="/broadcast">Рассылки</NavLink>
          </div>
        </nav>
        <div className="local-status">Локальная консоль</div>
      </aside>
      <main className="content" id="workspace" tabIndex={-1}>
        <ScrollToTop />
        <Boundary>
          <Routes>
            <Route path="/" element={<Navigate to="/overview" replace />} />
            <Route path="/overview" element={<Overview />} />
            <Route path="/users" element={<Users />} />
            <Route path="/users/:id" element={<UserDetail />} />
            <Route path="/reports" element={<Reports />} />
            <Route path="/news" element={<News />} />
            <Route path="/broadcast" element={<Broadcast />} />
          </Routes>
        </Boundary>
      </main>
    </div>
  );
}
