const app = require('./app');

const PORT = Number(process.env.PORT || 8080);

if (!process.env.DB_PASSWORD) {
  console.error('DB_PASSWORD is not set; refusing to start');
  process.exit(1);
}

const server = app.listen(PORT, () => {
  console.log(`listening on ${PORT}`);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
