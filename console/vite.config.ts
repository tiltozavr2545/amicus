import react from '@vitejs/plugin-react';
// The API port comes from the same .env the server reads: keeping the same
// number written down in two places is a guaranteed way to make them diverge.
import { defineConfig, loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '');
  const apiPort = env.CONSOLE_API_PORT ?? '5174';

  return {
    plugins: [react()],
    server: {
      // The console is local: listen on loopback only, don't serve to the network.
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
