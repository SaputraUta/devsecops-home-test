const express = require('express');

const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '8kb' }));

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

module.exports = app;
