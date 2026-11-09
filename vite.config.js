import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    host: '0.0.0.0',
    proxy: { '/api': 'http://localhost:8787' },
  },
  optimizeDeps: {
    noDiscovery: true,
    include: ['react', 'react-dom/client', 'react/jsx-runtime', '@supabase/supabase-js', 'lucide-react'],
  },
  build: {
    rollupOptions: {
      output: {
        manualChunks(id) {
          const path = id.replaceAll(String.fromCharCode(92), '/');
          if (path.includes('/node_modules/lucide-react/')) return 'icons';
          if (path.includes('/node_modules/@supabase/')) return 'supabase';
          if (path.includes('/node_modules/react/') || path.includes('/node_modules/react-dom/')) return 'react';
        },
      },
    },
  },
});
