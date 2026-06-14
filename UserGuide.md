Démarrer
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d — et active ton tunnel WireGuard pour tout ce qui est admin.
L'appli (public, navigateur)
https://ecotrack.local — l'API et le dashboard live des bacs. Pas besoin de VPN.
Grafana (les KPI déchets)
http://172.20.4.50:3000 — admin / ecotrack_grafana_pwd. Dashboard « ECOTRACK - Gestion des déchets » : remplissage par zone, bacs à collecter, taux de valorisation, carte des bacs.
Wazuh (le SOC)
https://172.20.4.30:5601 — admin / SecretPassword. Les alertes, les attaques détectées, et Threat Intelligence → MITRE ATT&CK. L'agent et sa FIM sont dans le menu Agents.
Prometheus (les métriques brutes)
http://172.20.4.40:9090 — tape waste_diversion_rate_percent ou waste_bins_to_collect pour voir les KPI. Onglet Alerts pour les règles.
Alertmanager (le routage d'alertes)
http://172.20.4.60:9093 — les alertes actives et les silences.
Tester tout d'un coup
powershell -ExecutionPolicy Bypass -File .\test-ecotrack.ps1 — VPN actif, ~10-15 min (il lance aussi nmap/sqlmap). Vérifie segmentation, WAF, détection, backup.
Tester une attaque (et voir Wazuh réagir)
curl.exe -sk "https://ecotrack.local/health" -o NUL -w "%{http_code}`n"    --- Doit renvoyé 200
docker stop ecotrack-cadvisor — attends ~3 min, l'alerte part dans Alertmanager et le webhook (docker logs ecotrack-webhook-logger). Relance avec docker start ecotrack-cadvisor.