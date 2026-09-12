import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Порт API берётся из того же .env, что читает сервер: держать два места,
// где записан один и тот же номер, — гарантированный способ их разъединить.
import { loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const apiPort = env.CONSOLE_API_PORT ?? '5174';

  return {
    plugins: [react()],
    server: {
      // Консоль локальная: слушать только петлю, не раздавать себя в сеть.
      host: '127.0.0.1',
      port: 5173,
      strictPort: true,
      proxy: {
        '/api': {
          target: `http://127.0.0.1:${apiPort}`,
          changeOrigin: false,
        },
      },
    },
  };
});
