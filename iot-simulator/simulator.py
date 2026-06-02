import os
import time
import random

import requests
from prometheus_client import start_http_server, Counter, Gauge, Histogram

API_URL = os.environ.get("API_URL", "http://172.20.5.20:3000")
INTERVAL = int(os.environ.get("SIM_INTERVAL", "5"))
DEVICES = int(os.environ.get("SIM_DEVICES", "10"))
METRICS_PORT = int(os.environ.get("SIM_METRICS_PORT", "8000"))

BASE_LAT, BASE_LON = 48.8566, 2.3522

READINGS_SENT = Counter("iot_readings_sent_total", "Total IoT readings successfully sent", ["device_id"])
POST_ERRORS = Counter("iot_post_errors_total", "Total failed IoT POST requests", ["device_id"])
POST_LATENCY = Histogram("iot_post_duration_seconds", "Latency of IoT POST requests to the API")
LAST_VALUE = Gauge("iot_last_value", "Last value emitted per device", ["device_id"])
DEVICES_ACTIVE = Gauge("iot_devices_active", "Number of IoT devices being simulated")
API_UP = Gauge("iot_api_up", "Whether the API /health endpoint is reachable (1/0)")
CYCLES = Counter("iot_cycles_total", "Total simulation cycles completed")


def wait_for_api():
    for _ in range(60):
        try:
            r = requests.get(f"{API_URL}/health", timeout=3)
            if r.status_code == 200:
                API_UP.set(1)
                return True
        except requests.RequestException:
            pass
        API_UP.set(0)
        time.sleep(3)
    return False


def main():
    start_http_server(METRICS_PORT)
    DEVICES_ACTIVE.set(DEVICES)
    wait_for_api()
    while True:
        for i in range(DEVICES):
            device_id = f"sensor-{i:03d}"
            value = round(random.uniform(0, 100), 2)
            payload = {
                "device_id": device_id,
                "value": value,
                "lat": round(BASE_LAT + random.uniform(-0.05, 0.05), 6),
                "lon": round(BASE_LON + random.uniform(-0.05, 0.05), 6),
            }
            try:
                with POST_LATENCY.time():
                    r = requests.post(f"{API_URL}/api/iot", json=payload, timeout=5)
                if r.status_code < 400:
                    READINGS_SENT.labels(device_id=device_id).inc()
                    LAST_VALUE.labels(device_id=device_id).set(value)
                    API_UP.set(1)
                else:
                    POST_ERRORS.labels(device_id=device_id).inc()
            except requests.RequestException as e:
                POST_ERRORS.labels(device_id=device_id).inc()
                API_UP.set(0)
                print("post error", e, flush=True)
        CYCLES.inc()
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()