const app = require('./app');

const PORT = Number(process.env.PORT || 8080);

// Injected at container start by ECS from Secrets Manager (see architecture/decisions.md).
// Only presence is checked. Never log the value or process.env.
if (!process.env.DB_PASSWORD) {
  console.error('DB_PASSWORD is not set; refusing to start');
  process.exit(1);
}

const server = app.listen(PORT, () => {
  console.log(`listening on ${PORT}`);
});

// ECS sends SIGTERM before stopping a task; close cleanly so in-flight requests finish.
process.on('SIGTERM', () => server.close(() => process.exit(0)));
