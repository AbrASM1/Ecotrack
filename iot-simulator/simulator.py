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

COLLECT_THRESHOLD = float(os.environ.get("WASTE_COLLECT_THRESHOLD", "80"))
OVERFLOW_THRESHOLD = float(os.environ.get("WASTE_OVERFLOW_THRESHOLD", "90"))
COLLECT_PROB = float(os.environ.get("WASTE_COLLECT_PROB", "0.15"))
TEMP_ALERT = float(os.environ.get("WASTE_TEMP_ALERT", "50"))

if not VERIFY_TLS:
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# code: (libelle, densite_kg_par_litre, capacite_litres, temp_base_C, valorise)
CATEGORIES = {
    "GEN": ("ordures menageres", 0.12, 660, 18, False),
    "REC": ("emballages recyclables", 0.05, 660, 16, True),
    "ORG": ("biodechets", 0.35, 240, 24, True),
    "GLA": ("verre", 0.30, 1100, 15, True),
    "PAP": ("papier carton", 0.08, 660, 16, True),
    "TEX": ("textile", 0.10, 240, 16, False),
    "EWA": ("dechets electroniques", 0.20, 120, 17, False),
    "HAZ": ("dechets dangereux", 0.15, 120, 17, False),
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

ZONE_FACTOR = {z: random.uniform(0.7, 1.5) for z in ZONES}

READINGS = Counter("iot_readings_sent_total", "Readings successfully sent to the API", ["sensor_type", "zone"])
ERRORS = Counter("iot_post_errors_total", "Failed IoT POST requests", ["sensor_type"])
ANOMALIES = Counter("iot_anomalies_total", "Overflow events beyond threshold", ["sensor_type"])
LATENCY = Histogram("iot_post_duration_seconds", "Latency of IoT POST requests to the API")
CYCLES = Counter("iot_cycles_total", "Simulation cycles completed")

FLEET = Gauge("iot_fleet_size", "Total bins in the fleet")
BY_TYPE = Gauge("iot_sensors_by_type", "Bins per category", ["sensor_type"])
ACTIVE = Gauge("iot_active_sensors", "Bins online this cycle")
OFFLINE = Gauge("iot_offline_sensors", "Bins offline this cycle")
VAVG = Gauge("iot_value_avg", "Average fill level per category", ["sensor_type"])
VMIN = Gauge("iot_value_min", "Minimum fill level per category", ["sensor_type"])
VMAX = Gauge("iot_value_max", "Maximum fill level per category", ["sensor_type"])
ANOM_ACTIVE = Gauge("iot_anomaly_active", "Bins currently overflowing per category", ["sensor_type"])
API_UP = Gauge("iot_api_up", "Whether the API /health endpoint is reachable (1/0)")
BATCH_G = Gauge("iot_batch_size", "Bins posted per cycle")

W_FILL_AVG = Gauge("waste_fill_percent_avg", "Average fill level (%)", ["category", "zone"])
W_BINS = Gauge("waste_bins_total", "Total smart bins")
W_BY_CAT = Gauge("waste_bins_by_category", "Bins per category", ["category"])
W_TO_COLLECT = Gauge("waste_bins_to_collect", "Bins at or above the collection threshold", ["category"])
W_OVERFLOW = Gauge("waste_bins_overflow", "Bins at or above the overflow threshold", ["category"])
W_FILLRATE = Gauge("waste_fill_rate_percent_per_hour", "Average fill rate (%/h)", ["category"])
W_UTIL = Gauge("waste_capacity_utilization_percent", "Fleet capacity utilization (%)")
W_DIVERSION = Gauge("waste_diversion_rate_percent", "Share of recoverable waste volume (%)")
W_TEMP = Gauge("waste_bin_temperature_celsius_avg", "Average internal temperature (C)", ["category"])
W_TEMP_ALERT = Gauge("waste_bins_temperature_alert", "Bins above the temperature alert threshold")
W_BATTERY = Gauge("waste_battery_percent_avg", "Average sensor battery level (%)")
W_WEIGHT = Gauge("waste_bin_weight_kg_avg", "Average bin weight (kg)", ["category"])
W_OFFLINE = Gauge("waste_bins_offline", "Bins not reporting this cycle")
W_FILL_AT_COLLECTION = Gauge("waste_fill_at_collection_avg_percent", "Average fill level at collection (%)")
W_COLLECTIONS = Counter("waste_collections_total", "Bin collections performed", ["category", "zone"])
W_OVERFLOW_EVENTS = Counter("waste_overflow_events_total", "Overflow events", ["category"])
W_COLLECTED_KG = Counter("waste_collected_kg_total", "Waste collected (kg)", ["category"])

session = requests.Session()
session.verify = VERIFY_TLS
session.mount("https://", HTTPAdapter(pool_connections=WORKERS, pool_maxsize=WORKERS, max_retries=0))
session.mount("http://", HTTPAdapter(pool_connections=WORKERS, pool_maxsize=WORKERS, max_retries=0))


def build_fleet():
    bins = []
    cats = list(CATEGORIES.items())
    zones = list(ZONES.items())
    for i in range(FLEET_SIZE):
        code, (label, density, capacity, tbase, _) = cats[i % len(cats)]
        zname, (zlat, zlon) = zones[(i // len(cats)) % len(zones)]
        seq = i // (len(cats) * len(zones)) + 1
        bins.append({
            "id": f"{code}-{zname}-{seq:04d}",
            "cat": code,
            "zone": zname,
            "lat": round(zlat + random.uniform(-0.01, 0.01), 6),
            "lon": round(zlon + random.uniform(-0.01, 0.01), 6),
            "capacity": capacity,
            "density": density,
            "tbase": tbase,
            "fill": random.uniform(5, 55),
            "rate": random.uniform(0.15, 0.55) * ZONE_FACTOR[zname],
            "battery": random.uniform(55, 100),
            "temp": tbase + random.uniform(-2, 4),
            "was_overflow": False,
            "offline": False,
        })
    return bins


FLEET_DATA = build_fleet()
_fac_ema = {"v": 70.0}


def step_fleet():
    coll_fills = []
    for b in FLEET_DATA:
        b["offline"] = random.random() < OFFLINE_RATE
        if b["offline"]:
            continue
        b["fill"] = min(100.0, b["fill"] + b["rate"] + random.uniform(-0.05, 0.2))
        b["battery"] = max(0.0, b["battery"] - random.uniform(0.0, 0.03))
        if b["battery"] < 8:
            b["battery"] = 100.0
        warm = 6 if b["cat"] in ("ORG", "GEN") else 0
        b["temp"] = b["tbase"] + warm * (b["fill"] / 100.0) + random.uniform(-1.5, 1.5)
        if random.random() < 0.0008:
            b["temp"] += random.uniform(15, 40)

        if b["fill"] >= OVERFLOW_THRESHOLD and not b["was_overflow"]:
            W_OVERFLOW_EVENTS.labels(b["cat"]).inc()
            b["was_overflow"] = True

        collect = (b["fill"] >= COLLECT_THRESHOLD and random.random() < COLLECT_PROB) or b["fill"] >= 99
        if collect:
            kg = b["fill"] / 100.0 * b["capacity"] * b["density"]
            W_COLLECTIONS.labels(b["cat"], b["zone"]).inc()
            W_COLLECTED_KG.labels(b["cat"]).inc(kg)
            coll_fills.append(b["fill"])
            b["fill"] = random.uniform(0, 5)
            b["was_overflow"] = False

    if coll_fills:
        avg_c = sum(coll_fills) / len(coll_fills)
        _fac_ema["v"] = 0.9 * _fac_ema["v"] + 0.1 * avg_c
    W_FILL_AT_COLLECTION.set(round(_fac_ema["v"], 1))


def publish_metrics():
    online = [b for b in FLEET_DATA if not b["offline"]]
    offline_n = len(FLEET_DATA) - len(online)
    FLEET.set(len(FLEET_DATA))
    W_BINS.set(len(FLEET_DATA))
    ACTIVE.set(len(online))
    OFFLINE.set(offline_n)
    W_OFFLINE.set(offline_n)

    by_cat = {c: [] for c in CATEGORIES}
    by_cat_zone = {}
    temp_by_cat = {c: [] for c in CATEGORIES}
    weight_by_cat = {c: [] for c in CATEGORIES}
    rate_by_cat = {c: [] for c in CATEGORIES}
    to_collect = {c: 0 for c in CATEGORIES}
    overflow = {c: 0 for c in CATEGORIES}
    temp_alerts = 0
    batt = []
    vol_total = 0.0
    vol_div = 0.0

    for b in FLEET_DATA:
        c = b["cat"]
        if b["offline"]:
            continue
        by_cat[c].append(b["fill"])
        by_cat_zone.setdefault((c, b["zone"]), []).append(b["fill"])
        temp_by_cat[c].append(b["temp"])
        rate_by_cat[c].append(b["rate"] * (3600.0 / INTERVAL))
        w = b["fill"] / 100.0 * b["capacity"] * b["density"]
        weight_by_cat[c].append(w)
        batt.append(b["battery"])
        if b["fill"] >= COLLECT_THRESHOLD:
            to_collect[c] += 1
        if b["fill"] >= OVERFLOW_THRESHOLD:
            overflow[c] += 1
        if b["temp"] >= TEMP_ALERT:
            temp_alerts += 1
        liters = b["fill"] / 100.0 * b["capacity"]
        vol_total += liters
        if CATEGORIES[c][4]:
            vol_div += liters

    for c in CATEGORIES:
        n = len(by_cat[c])
        BY_TYPE.labels(c).set(n)
        W_BY_CAT.labels(c).set(n)
        W_TO_COLLECT.labels(c).set(to_collect[c])
        W_OVERFLOW.labels(c).set(overflow[c])
        ANOM_ACTIVE.labels(c).set(overflow[c])
        if n:
            vals = by_cat[c]
            VAVG.labels(c).set(round(sum(vals) / n, 2))
            VMIN.labels(c).set(round(min(vals), 2))
            VMAX.labels(c).set(round(max(vals), 2))
            W_TEMP.labels(c).set(round(sum(temp_by_cat[c]) / n, 2))
            W_WEIGHT.labels(c).set(round(sum(weight_by_cat[c]) / n, 2))
            W_FILLRATE.labels(c).set(round(sum(rate_by_cat[c]) / n, 2))

    for (c, z), vals in by_cat_zone.items():
        W_FILL_AVG.labels(c, z).set(round(sum(vals) / len(vals), 2))

    if online:
        W_UTIL.set(round(sum(b["fill"] for b in online) / len(online), 2))
        W_BATTERY.set(round(sum(batt) / len(batt), 1))
    W_TEMP_ALERT.set(temp_alerts)
    W_DIVERSION.set(round(100.0 * vol_div / vol_total, 1) if vol_total else 0.0)


def post_reading(b):
    if random.random() < ERROR_RATE:
        url = f"{API_URL}/api/iot_unavailable"
    else:
        url = f"{API_URL}/api/iot"
    payload = {"device_id": b["id"], "value": round(b["fill"], 1), "lat": b["lat"], "lon": b["lon"]}
    try:
        with LATENCY.time():
            r = session.post(url, json=payload, timeout=8)
        if r.status_code in (200, 201):
            READINGS.labels(b["cat"], b["zone"]).inc()
            if b["fill"] >= OVERFLOW_THRESHOLD:
                ANOMALIES.labels(b["cat"]).inc()
        else:
            ERRORS.labels(b["cat"]).inc()
    except Exception:
        ERRORS.labels(b["cat"]).inc()


def wait_for_api():
    url = f"{API_URL}/health"
    for _ in range(60):
        try:
            r = session.get(url, timeout=5)
            if r.status_code == 200:
                API_UP.set(1)
                return
        except Exception:
            pass
        API_UP.set(0)
        time.sleep(3)


def main():
    start_http_server(METRICS_PORT)
    wait_for_api()
    cursor = 0
    pool = ThreadPoolExecutor(max_workers=WORKERS)
    while True:
        step_fleet()
        publish_metrics()
        try:
            r = session.get(f"{API_URL}/health", timeout=5)
            API_UP.set(1 if r.status_code == 200 else 0)
        except Exception:
            API_UP.set(0)
        batch = [FLEET_DATA[(cursor + i) % len(FLEET_DATA)] for i in range(min(BATCH, len(FLEET_DATA)))]
        batch = [b for b in batch if not b["offline"]]
        cursor = (cursor + BATCH) % len(FLEET_DATA)
        BATCH_G.set(len(batch))
        list(pool.map(post_reading, batch))
        CYCLES.inc()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()