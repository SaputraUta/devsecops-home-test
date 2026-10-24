const express = require('express');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '8kb' }));
app.use((req, res, next) => {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; form-action 'none'; base-uri 'none'",
    'Cache-Control': 'no-store',
  });
  next();
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok' });
});

app.get('/api/orders/:id', (req, res) => {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ error: 'invalid id' });
  }
  res.json({ id, status: 'shipped' });
});

app.use((req, res) => {
  res.status(404).json({ error: 'not found' });
});

module.exports = app;
