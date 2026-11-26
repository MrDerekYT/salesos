/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    './pages/**/*.{js,ts,jsx,tsx,mdx}',
    './components/**/*.{js,ts,jsx,tsx,mdx}',
    './app/**/*.{js,ts,jsx,tsx,mdx}',
  ],
  theme: {
    extend: {
      colors: {
        background: '#0a0a0f',
        card: 'rgba(255,255,255,0.03)',
        accent: '#3b82f6',
        success: '#10b981',
        warning: '#f59e0b',
      },
    },
  },
  plugins: [],
}