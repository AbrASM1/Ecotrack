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

const DASH_HTML = `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ECOTRACK - Live IoT</title>
<style>
 body{margin:0;font-family:system-ui,Segoe UI,Roboto,sans-serif;background:#0b0f14;color:#e6edf3}
 header{padding:14px 18px;border-bottom:1px solid #1f2a36;display:flex;gap:24px;align-items:center;flex-wrap:wrap}
 h1{font-size:16px;margin:0;letter-spacing:.5px;color:#6fd3c7}
 .stat{font-size:13px;color:#9fb0c0}.stat b{color:#e6edf3;font-size:15px}
 .dot{width:8px;height:8px;border-radius:50%;display:inline-block;margin-right:6px;background:#3fb950}
 .dot.off{background:#f85149}
 main{display:grid;grid-template-columns:1fr 1fr;gap:0;height:calc(100vh - 53px)}
 .panel{padding:14px 18px;overflow:auto}.panel.left{border-right:1px solid #1f2a36}
 table{width:100%;border-collapse:collapse;font-size:13px}
 th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #161f29}
 th{color:#7d8da0;font-weight:600;position:sticky;top:0;background:#0b0f14}
 td.v{font-variant-numeric:tabular-nums}
 .new{animation:fade 1.6s ease-out}
 @keyframes fade{from{background:#173a32}to{background:transparent}}
 svg{width:100%;height:auto;background:#0d141c;border:1px solid #1f2a36;border-radius:8px}
 .err{color:#f85149}
</style>
</head>
<body>
<header>
 <h1>ECOTRACK / LIVE IoT</h1>
 <div class="stat"><span id="d" class="dot"></span><span id="status">connexion...</span></div>
 <div class="stat">releves <b id="count">0</b></div>
 <div class="stat">capteurs <b id="devices">0</b></div>
 <div class="stat">dernier <b id="last">-</b></div>
</header>
<main>
 <div class="panel left">
  <table><thead><tr><th>capteur</th><th>valeur</th><th>lat</th><th>lon</th><th>heure</th></tr></thead>
  <tbody id="rows"></tbody></table>
 </div>
 <div class="panel"><svg id="map" viewBox="0 0 500 420" preserveAspectRatio="xMidYMid meet"></svg></div>
</main>
<script>
var LAT0=48.806,LAT1=48.907,LON0=2.302,LON1=2.402;
function x(lon){return 20+(lon-LON0)/(LON1-LON0)*460}
function y(lat){return 400-(lat-LAT0)/(LAT1-LAT0)*380}
function color(v){var t=Math.max(0,Math.min(100,v))/100;return 'rgb('+Math.round(60+t*180)+','+Math.round(200-t*150)+',90)'}
function pad(n){return (n<10?'0':'')+n}
function hhmmss(d){return pad(d.getHours())+':'+pad(d.getMinutes())+':'+pad(d.getSeconds())}
var seen={};
function draw(rows){
 var byDev={};for(var i=0;i<rows.length;i++){if(!byDev[rows[i].device_id])byDev[rows[i].device_id]=rows[i];}
 var pts='';for(var k in byDev){var r=byDev[k];pts+='<circle cx="'+x(r.lon).toFixed(1)+'" cy="'+y(r.lat).toFixed(1)+'" r="5" fill="'+color(r.value)+'" opacity="0.9"><title>'+k+' = '+r.value+'</title></circle>';}
 document.getElementById('map').innerHTML='<rect x="20" y="20" width="460" height="380" fill="none" stroke="#1f2a36"/><text x="20" y="415" fill="#5a6b7b" font-size="10">'+LON0+'E</text><text x="440" y="415" fill="#5a6b7b" font-size="10">'+LON1+'E</text>'+pts;
}
function rowsHtml(rows){var h='';for(var i=0;i<Math.min(rows.length,20);i++){var r=rows[i];var isnew=!seen[r.id];seen[r.id]=1;h+='<tr class="'+(isnew?'new':'')+'"><td>'+r.device_id+'</td><td class="v">'+Number(r.value).toFixed(2)+'</td><td class="v">'+Number(r.lat).toFixed(4)+'</td><td class="v">'+Number(r.lon).toFixed(4)+'</td><td>'+hhmmss(new Date(r.recorded_at))+'</td></tr>';}return h;}
function tick(){
 fetch('/api/iot/latest',{cache:'no-store'}).then(function(res){return res.json()}).then(function(rows){
  document.getElementById('d').className='dot';document.getElementById('status').textContent='flux actif';
  document.getElementById('count').textContent=rows.length;
  var devs={};for(var i=0;i<rows.length;i++)devs[rows[i].device_id]=1;
  document.getElementById('devices').textContent=Object.keys(devs).length;
  if(rows.length)document.getElementById('last').textContent=hhmmss(new Date(rows[0].recorded_at));
  document.getElementById('rows').innerHTML=rowsHtml(rows);draw(rows);
 }).catch(function(){document.getElementById('d').className='dot off';document.getElementById('status').innerHTML='<span class="err">API injoignable</span>';});
}
tick();setInterval(tick,2000);
</script>
</body>
</html>`;

app.get('/dashboard', (req, res) => res.type('html').send(DASH_HTML));

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
      await pool.query('CREATE INDEX IF NOT EXISTS idx_iot_dev_time ON iot_readings (device_id, recorded_at DESC)');
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