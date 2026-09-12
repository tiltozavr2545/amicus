import { useEffect } from 'react';
import { NavLink, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { Boundary } from './components/boundary';
import { Overview } from './pages/Overview';
import { Broadcast } from './pages/Broadcast';
import { News } from './pages/News';
import { Reports } from './pages/Reports';
import { Users } from './pages/Users';
import { UserDetail } from './pages/UserDetail';

// Роутер сам прокрутку не сбрасывает: со списка, промотанного вниз, переход
// в карточку попадал в её середину.
function ScrollToTop() {
  const { pathname } = useLocation();
  useEffect(() => {
    window.scrollTo(0, 0);
  }, [pathname]);
  return null;
}

export function App() {
  return (
    <div className="layout">
      <aside className="sidebar">
        <p className="brand">Amicus</p>
        <p className="brand-sub">консоль · локально</p>
        <nav className="nav">
          <NavLink to="/overview" className={({ isActive }) => (isActive ? 'active' : '')}>
            Обзор
          </NavLink>
          <NavLink to="/users" className={({ isActive }) => (isActive ? 'active' : '')}>
            Пользователи
          </NavLink>
          <NavLink to="/reports" className={({ isActive }) => (isActive ? 'active' : '')}>
            Жалобы
          </NavLink>
          <NavLink to="/news" className={({ isActive }) => (isActive ? 'active' : '')}>
            Новости
          </NavLink>
          <NavLink to="/broadcast" className={({ isActive }) => (isActive ? 'active' : '')}>
            Рассылки
          </NavLink>
        </nav>
      </aside>
      <main className="content">
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
