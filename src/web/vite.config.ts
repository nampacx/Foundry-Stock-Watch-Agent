import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    // Local development: run the function app (`func start` in src/api, port 7071) next to `npm run dev`.
    proxy: { '/api': 'http://localhost:7071' },
  },
})
