const express = require('express');
const { Pool } = require('pg');
const { createClient } = require('redis');

const PORT = process.env.PORT || 3000;

const pool = new Pool({
  host: process.env.PGHOST,
  port: Number(process.env.PGPORT) || 5432,
  user: process.env.PGUSER,
  password: process.env.PGPASSWORD,
  database: process.env.PGDATABASE,
});

const redis = createClient({
  socket: { host: process.env.REDIS_HOST, port: Number(process.env.REDIS_PORT) || 6379 },
});
redis.on('error', (e) => console.error('redis error', e.message));

const app = express();
app.use(express.json());

app.get('/health', (req, res) => res.status(200).json({ status: 'ok' }));

app.post('/api/iot', async (req, res) => {
  const { device_id, value, lat, lon } = req.body || {};
  if (!device_id || value === undefined) {
    return res.status(400).json({ error: 'device_id and value required' });
  }
  try {
    const q = `INSERT INTO iot_readings (device_id, value, geom, recorded_at)
               VALUES ($1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326), NOW())
               RETURNING id, recorded_at`;
    const r = await pool.query(q, [device_id, value, lon ?? 0, lat ?? 0]);
    await redis.set(`device:${device_id}:last`, JSON.stringify({ value, lat, lon, ts: r.rows[0].recorded_at }));
    res.status(201).json({ id: r.rows[0].id });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/iot/latest', async (req, res) => {
  try {
    const r = await pool.query(
      'SELECT id, device_id, value, ST_X(geom) AS lon, ST_Y(geom) AS lat, recorded_at FROM iot_readings ORDER BY recorded_at DESC LIMIT 50'
    );
    res.json(r.rows);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

async function init() {
  for (let i = 0; i < 20; i++) {
    try {
      await pool.query('CREATE EXTENSION IF NOT EXISTS postgis');
      await pool.query(`CREATE TABLE IF NOT EXISTS iot_readings (
        id BIGSERIAL PRIMARY KEY,
        device_id TEXT NOT NULL,
        value DOUBLE PRECISION NOT NULL,
        geom geometry(Point, 4326),
        recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )`);
      break;
    } catch (e) {
      console.error('db init retry', i, e.message);
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  try { await redis.connect(); } catch (e) { console.error('redis connect', e.message); }
  app.listen(PORT, '0.0.0.0', () => console.log(`api listening on ${PORT}`));
}

init();