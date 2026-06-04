import os
import time
import random

import requests
import urllib3
from requests.adapters import HTTPAdapter
from concurrent.futures import ThreadPoolExecutor
from prometheus_client import start_http_server, Counter, Gauge, Histogram

API_URL = os.environ.get("API_URL", "https://172.20.5.30:8443")
VERIFY_TLS = os.environ.get("SIM_VERIFY_TLS", "false").lower() in ("1", "true", "yes")
INTERVAL = int(os.environ.get("SIM_INTERVAL", "5"))
FLEET_SIZE = int(os.environ.get("SIM_FLEET_SIZE", os.environ.get("SIM_DEVICES", "2000")))
BATCH = int(os.environ.get("SIM_BATCH", "200"))
WORKERS = int(os.environ.get("SIM_WORKERS", "40"))
METRICS_PORT = int(os.environ.get("SIM_METRICS_PORT", "8000"))
ERROR_RATE = float(os.environ.get("SIM_ERROR_RATE", "0.01"))
OFFLINE_RATE = float(os.environ.get("SIM_OFFLINE_RATE", "0.005"))

if not VERIFY_TLS:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SENSOR_TYPES = {
    "air_quality":   {"code": "AQ", "lo": 0.0,  "hi": 350.0, "anom": 200.0},
    "water_quality": {"code": "WQ", "lo": 0.0,  "hi": 100.0, "anom": 80.0},
    "noise":         {"code": "NS", "lo": 30.0, "hi": 110.0, "anom": 95.0},
    "temperature":   {"code": "TM", "lo": -5.0, "hi": 42.0,  "anom": 38.0},
    "humidity":      {"code": "HM", "lo": 10.0, "hi": 100.0, "anom": 90.0},
    "traffic":       {"code": "TR", "lo": 0.0,  "hi": 100.0, "anom": 85.0},
    "energy":        {"code": "EN", "lo": 0.0,  "hi": 100.0, "anom": 90.0},
    "waste":         {"code": "WS", "lo": 0.0,  "hi": 100.0, "anom": 85.0},
}

ZONES = {
    "Montmartre":    (48.8867, 2.3431),
    "Bastille":      (48.8533, 2.3692),
    "Marais":        (48.8590, 2.3620),
    "Belleville":    (48.8722, 2.3767),
    "Bercy":         (48.8333, 2.3833),
    "LaDefense":     (48.8920, 2.2360),
    "QuartierLatin": (48.8490, 2.3470),
    "Opera":         (48.8710, 2.3320),
    "Republique":    (48.8675, 2.3636),
    "Nation":        (48.8485, 2.3958),
    "Pigalle":       (48.8820, 2.3370),
    "Auteuil":       (48.8480, 2.2700),
    "Montparnasse":  (48.8400, 2.3220),
    "Batignolles":   (48.8870, 2.3170),
    "Vincennes":     (48.8470, 2.4340),
    "Tolbiac":       (48.8270, 2.3680),
}

READINGS = Counter("iot_readings_sent_total", "Readings successfully sent to the API", ["sensor_type", "zone"])
ERRORS = Counter("iot_post_errors_total", "Failed IoT POST requests", ["sensor_type"])
ANOMALIES = Counter("iot_anomalies_total", "Readings beyond the per-type threshold", ["sensor_type"])
LATENCY = Histogram("iot_post_duration_seconds", "Latency of IoT POST requests to the API")
CYCLES = Counter("iot_cycles_total", "Simulation cycles completed")

FLEET = Gauge("iot_fleet_size", "Total sensors in the fleet")
BY_TYPE = Gauge("iot_sensors_by_type", "Sensors per type", ["sensor_type"])
ACTIVE = Gauge("iot_active_sensors", "Sensors online this cycle")
OFFLINE = Gauge("iot_offline_sensors", "Sensors offline this cycle")
VAVG = Gauge("iot_value_avg", "Fleet average value per type", ["sensor_type"])
VMIN = Gauge("iot_value_min", "Fleet minimum value per type", ["sensor_type"])
VMAX = Gauge("iot_value_max", "Fleet maximum value per type", ["sensor_type"])
ANOM_ACTIVE = Gauge("iot_anomaly_active", "Sensors currently in anomaly per type", ["sensor_type"])
API_UP = Gauge("iot_api_up", "Whether the API /health endpoint is reachable (1/0)")
BATCH_G = Gauge("iot_batch_size", "Sensors posted per cycle")

session = requests.Session()
session.verify = VERIFY_TLS
session.mount("https://", HTTPAdapter(pool_connections=WORKERS, pool_maxsize=WORKERS, max_retries=0))
session.mount("http://", HTTPAdapter(pool_connections=WORKERS, pool_maxsize=WORKERS, max_retries=0))


def build_fleet():
    types = list(SENSOR_TYPES.items())
    zones = list(ZONES.items())
    fleet = []
    for i in range(FLEET_SIZE):
        tname, tinfo = types[i % len(types)]
        zname, (zlat, zlon) = zones[i % len(zones)]
        fleet.append({
            "id": "{0}-{1}-{2:04d}".format(tinfo["code"], zname, i),
            "type": tname,
            "zone": zname,
            "lat": round(zlat + random.uniform(-0.01, 0.01), 6),
            "lon": round(zlon + random.uniform(-0.01, 0.01), 6),
            "base": random.uniform(tinfo["lo"], tinfo["hi"]),
        })
    return fleet


FLEET_LIST = build_fleet()


def init_series():
    FLEET.set(FLEET_SIZE)
    counts = {}
    for s in FLEET_LIST:
        counts[s["type"]] = counts.get(s["type"], 0) + 1
    for tname in SENSOR_TYPES:
        BY_TYPE.labels(sensor_type=tname).set(counts.get(tname, 0))
        ERRORS.labels(sensor_type=tname)
        ANOMALIES.labels(sensor_type=tname)
        ANOM_ACTIVE.labels(sensor_type=tname).set(0)
        VAVG.labels(sensor_type=tname).set(0)
        VMIN.labels(sensor_type=tname).set(0)
        VMAX.labels(sensor_type=tname).set(0)
        for zname in ZONES:
            READINGS.labels(sensor_type=tname, zone=zname)


def gen_value(s):
    info = SENSOR_TYPES[s["type"]]
    span = (info["hi"] - info["lo"]) * 0.15
    v = s["base"] + random.uniform(-span, span)
    return round(max(info["lo"], min(info["hi"], v)), 2)


def post_one(item):
    s, value = item
    endpoint = "/api/iot_unavailable" if random.random() < ERROR_RATE else "/api/iot"
    payload = {"device_id": s["id"], "value": value, "lat": s["lat"], "lon": s["lon"]}
    try:
        with LATENCY.time():
            r = session.post(API_URL + endpoint, json=payload, timeout=5)
        if r.status_code < 400:
            READINGS.labels(sensor_type=s["type"], zone=s["zone"]).inc()
            return True
        ERRORS.labels(sensor_type=s["type"]).inc()
        return False
    except requests.RequestException:
        ERRORS.labels(sensor_type=s["type"]).inc()
        return False


def wait_for_api():
    for _ in range(60):
        try:
            if session.get(API_URL + "/health", timeout=3).status_code == 200:
                API_UP.set(1)
                return True
        except requests.RequestException:
            pass
        API_UP.set(0)
        time.sleep(3)
    return False


def main():
    start_http_server(METRICS_PORT)
    init_series()
    wait_for_api()
    pool = ThreadPoolExecutor(max_workers=WORKERS)
    ptr = 0
    while True:
        agg = {t: [] for t in SENSOR_TYPES}
        values = {}
        for s in FLEET_LIST:
            v = gen_value(s)
            values[s["id"]] = v
            agg[s["type"]].append(v)
        for tname, vals in agg.items():
            if not vals:
                continue
            VAVG.labels(sensor_type=tname).set(round(sum(vals) / len(vals), 2))
            VMIN.labels(sensor_type=tname).set(min(vals))
            VMAX.labels(sensor_type=tname).set(max(vals))
            thr = SENSOR_TYPES[tname]["anom"]
            nanom = sum(1 for x in vals if x >= thr)
            ANOM_ACTIVE.labels(sensor_type=tname).set(nanom)
            if nanom:
                ANOMALIES.labels(sensor_type=tname).inc(nanom)

        offline = set()
        k = int(FLEET_SIZE * OFFLINE_RATE)
        if k > 0:
            offline = set(random.sample(range(FLEET_SIZE), k))
        ACTIVE.set(FLEET_SIZE - len(offline))
        OFFLINE.set(len(offline))

        batch = []
        i = ptr
        target = min(BATCH, FLEET_SIZE)
        scanned = 0
        while len(batch) < target and scanned < FLEET_SIZE:
            idx = i % FLEET_SIZE
            if idx not in offline:
                s = FLEET_LIST[idx]
                batch.append((s, values[s["id"]]))
            i += 1
            scanned += 1
        ptr = (ptr + BATCH) % FLEET_SIZE
        BATCH_G.set(len(batch))

        results = list(pool.map(post_one, batch))
        API_UP.set(1 if any(results) else 0)
        CYCLES.inc()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()