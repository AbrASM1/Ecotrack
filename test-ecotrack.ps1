#requires -Version 5.1
# ECOTRACK - full stack smoke test (Windows 11 / Docker Desktop)
# Run: powershell -ExecutionPolicy Bypass -File .\test-ecotrack.ps1

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

function PgQuery($sql) {
  $out = docker exec ecotrack-postgres psql -U ecotrack -d ecotrack -tAc $sql 2>&1
  return (($out -join "`n").Trim())
}

# Admin UIs are no longer published on the host (VPN-only). Reach them via the
# monitoring network from a one-shot container. Returns @{ ok; body }.
$script:monNet = (docker network ls --format "{{.Name}}" | Select-String -Pattern "_monitoring$" | Select-Object -First 1)
if ($script:monNet) { $script:monNet = $script:monNet.ToString().Trim() } else { $script:monNet = "filerouge3_monitoring" }
function HttpMon($url) {
  $body = docker run --rm --network $script:monNet curlimages/curl:latest -sk --max-time 8 $url 2>&1
  $body = ($body -join "`n")
  if ($LASTEXITCODE -eq 0) { return @{ ok = $true; body = $body } }
  return @{ ok = $false; body = $body }
}

# api is debian-based: use bash /dev/tcp to probe inter-container reachability
function TcpFromApi($ip, $port) {
  $cmd = "exec 3<>/dev/tcp/$ip/$port && echo OPEN || echo CLOSED"
  $o = docker exec ecotrack-api timeout 3 bash -c $cmd 2>&1
  return (($o -join '').Trim())
}

Write-Host "ECOTRACK smoke test" -ForegroundColor White
Write-Host ("PowerShell {0} | {1}" -f $PSVersionTable.PSVersion, (Get-Date)) -ForegroundColor DarkGray

# --- 0. Docker available ---
Section "Docker engine"
docker version --format '{{.Server.Version}}' 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { Pass "docker daemon reachable" } else { Fail "docker daemon not reachable - is Docker Desktop running?"; Write-Host "RESULT: aborted"; exit 1 }

# --- 1. Containers running / healthy ---
Section "Containers (14 expected)"
$expected = @(
  'ecotrack-postgres', 'ecotrack-redis', 'ecotrack-api', 'ecotrack-iot-simulator',
  'ecotrack-nginx-waf', 'ecotrack-suricata', 'ecotrack-wireguard',
  'ecotrack-wazuh-indexer', 'ecotrack-wazuh-manager', 'ecotrack-wazuh-dashboard',
  'ecotrack-prometheus', 'ecotrack-grafana', 'ecotrack-alertmanager', 'ecotrack-node-exporter'
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

$r = HttpMon "http://172.20.4.60:9093/-/healthy"
if ($r.ok -and $r.body -match 'Healthy') { Pass "Alertmanager /-/healthy (via reseau interne)" } else { Fail "Alertmanager injoignable en interne" }

$r = HttpMon "http://172.20.4.70:9100/metrics"
if ($r.ok -and $r.body -match 'node_') { Pass "node-exporter /metrics OK (via reseau interne)" } else { Fail "node-exporter injoignable en interne" }

# --- 6. Perimeter IDS / VPN ---
Section "IDS / VPN"
$ver = (docker exec ecotrack-suricata suricata --version 2>&1) -join ' '
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

# --- 10. Chantier 3: detection + generation d'alertes ---
Section "Chantier 3 - Detection (genere des alertes)"
$rc = (docker exec ecotrack-wazuh-manager sh -c "grep -c 'rule id' /var/ossec/etc/rules/local_rules.xml" 2>&1) -join ''
if ($rc -match '^\s*5') { Pass "wazuh local_rules.xml monte (5 regles de correlation)" } else { Warn "local_rules.xml: $rc regle(s) detectee(s)" }

$ev0 = (docker exec ecotrack-suricata sh -c "test -f /var/log/suricata/eve.json && wc -l < /var/log/suricata/eve.json || echo 0" 2>&1) -join ''

function NumOf($s) { $t = ("$s").Trim(); if ($t -match '^\d+$') { [int64]$t } else { [int64]0 } }

Write-Host "  [..] injection SQLi + sqlmap UA via le WAF (http://localhost)..." -ForegroundColor DarkGray
try { Invoke-WebRequest -Uri "http://localhost/api/iot/latest?id=1%20UNION%20SELECT%20username,password%20FROM%20pg_user--" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null } catch {}
try { Invoke-WebRequest -Uri "http://localhost/api/iot/latest" -Headers @{ 'User-Agent' = 'sqlmap/1.7.2' } -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop | Out-Null } catch {}
try { 1..6 | ForEach-Object { Invoke-WebRequest -Uri "http://localhost/api/iot/latest?x=$_%27%20OR%20%271%27=%271" -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop | Out-Null } } catch {}
Start-Sleep -Seconds 12

$suriRun = (docker inspect -f '{{.State.Running}}' ecotrack-suricata 2>&1) -join ''
if ($suriRun -match 'true') {
  $ev1 = NumOf (docker exec ecotrack-suricata sh -c "wc -l < /var/log/suricata/eve.json 2>/dev/null || echo 0" 2>&1)
  if ($ev1 -gt 0) { Pass "suricata eve.json alimente ($ev1 lignes) - sidecar voit l'ingress WAF" } else { Warn "eve.json vide - verifier interface (docker exec ecotrack-suricata ip -o -4 addr)" }
  $alerts = NumOf (docker exec ecotrack-suricata sh -c "grep -c event_type.:.alert /var/log/suricata/eve.json 2>/dev/null || echo 0" 2>&1)
  if ($alerts -gt 0) { Pass "suricata: $alerts alerte(s) IDS levee(s) sur regles ECOTRACK" } else { Warn "0 alerte IDS - capture sidecar ne voit pas le trafic, voir notes interface" }
} else {
  Warn "suricata pas 'running' (state=$suriRun) - eve.json non verifie, corriger le conteneur d'abord"
}

$mods = NumOf (docker exec ecotrack-nginx-waf sh -c "test -f /var/log/nginx/modsec_audit.log && grep -c '9000001' /var/log/nginx/modsec_audit.log || echo 0" 2>&1)
if ($mods -gt 0) { Pass "ModSecurity: $mods hit(s) regle 9000001 (SQLi /api) dans modsec_audit.log" } else { Warn "0 hit ModSec custom 9000001 - voir 'tail modsec_audit.log' (CRS natif 942xxx a pu matcher avant)" }

# --- 11. Wazuh: bruit SCA coupe + alertes securite cote manager ---
Section "Wazuh - Alertes (SCA coupe + detection)"
$sca = (docker exec ecotrack-wazuh-manager sh -c "grep -A2 '<sca>' /var/ossec/etc/ossec.conf | grep -c '<enabled>no</enabled>'" 2>&1) -join ''
if ($sca.Trim() -eq '1') { Pass "module SCA desactive dans ossec.conf (plus de bruit CIS)" } else { Warn "SCA pas confirme desactive - verifier montage wazuh_manager.conf" }

$lf = (docker exec ecotrack-wazuh-manager sh -c "grep -c 'ecotrack_access.log\|suricata/eve.json' /var/ossec/etc/ossec.conf" 2>&1) -join ''
if (([int]($lf.Trim() -replace '\D','')) -ge 2) { Pass "localfile nginx + suricata injectes dans le manager (logs -> analysisd)" } else { Warn "localfile ECOTRACK absents de ossec.conf" }

Write-Host "  [..] generation d'alertes (SQLi/scanner) cote manager..." -ForegroundColor DarkGray
try { 1..8 | ForEach-Object { Invoke-WebRequest -Uri "http://localhost/api/iot/latest?id=1%20UNION%20SELECT%20username,password%20FROM%20pg_user--" -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop | Out-Null } } catch {}
try { 1..4 | ForEach-Object { Invoke-WebRequest -Uri "http://localhost/api/iot/latest" -Headers @{ 'User-Agent' = 'sqlmap/1.7.2' } -UseBasicParsing -TimeoutSec 6 -ErrorAction Stop | Out-Null } } catch {}

# reseau dmz du projet (autodetection du prefixe compose)
$dmznet = (docker network ls --format "{{.Name}}" | Select-String -Pattern "_dmz$" | Select-Object -First 1).ToString().Trim()
if (-not $dmznet) { $dmznet = "filerouge3_dmz" }
$wafip = "172.20.1.10"

Write-Host "  [..] scan nmap (docker instrumentisto/nmap) sur $wafip via $dmznet ..." -ForegroundColor DarkGray
docker run --rm --network $dmznet instrumentisto/nmap -Pn -T4 -p 1-300,8080,8443 --script http-sql-injection $wafip 2>&1 | Out-Null

Write-Host "  [..] scan sqlmap (docker python:3-slim + pip) ..." -ForegroundColor DarkGray
docker run --rm --network $dmznet python:3-slim sh -c "pip install --quiet --root-user-action=ignore sqlmap >/dev/null 2>&1; sqlmap -u 'http://$wafip`:8080/api/iot/latest?id=1' --batch --flush-session --level=1 --risk=1 --technique=B --threads=4 2>&1 | tail -3" 2>&1 | Out-Null

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
if ($cc -gt 0) { Pass "wazuh-alerts CRITICAL (niveau>=12): $cc" } else { Warn "0 alerte critical - lancer les scans nmap/sqlmap (section suivante) puis relancer" }

$high = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.level:[8 TO 11]'" 2>&1) -join ''
$hc = 0; if ($high -match '"count":(\d+)') { $hc = [int]$Matches[1] }
if ($hc -gt 0) { Pass "wazuh-alerts HIGH (niveau 8-11): $hc" } else { Warn "0 alerte high (niveau 8-11)" }

foreach ($rid in @('100110','100111','100112','100113','31103','31106')) {
  $rr = (docker exec ecotrack-wazuh-indexer sh -c "curl -sk -G -u admin:SecretPassword 'https://localhost:9200/wazuh-alerts-*/_count' --data-urlencode 'q=rule.id:$rid'" 2>&1) -join ''
  $rc2 = 0; if ($rr -match '"count":(\d+)') { $rc2 = [int]$Matches[1] }
  if ($rc2 -gt 0) { Pass "regle Wazuh $rid declenchee x$rc2" }
}

# --- 12bis. Block mode: ModSecurity bloque (403), statut IDS/IPS ---
Section "Block mode - WAF (ModSecurity On) + IDS/IPS"
$eng = (docker exec ecotrack-nginx-waf sh -c "env | grep -i MODSEC_RULE_ENGINE" 2>&1) -join ''
if ($eng -match '=\s*On') { Pass "ModSecurity engine = On (blocage actif)" } else { Warn "MODSEC_RULE_ENGINE != On ($eng)" }

$benign = Http "http://localhost/api/iot/latest"
if ($benign.code -eq 200) { Pass "trafic legitime -> 200 (pas de faux positif)" } else { Warn "trafic legitime code=$($benign.code) (faux positif WAF ?)" }

$code = 0
try { $x = Invoke-WebRequest -Uri "http://localhost/api/iot/latest?id=1%20UNION%20SELECT%20username,password%20FROM%20pg_user--" -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop; $code = [int]$x.StatusCode } catch { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode.value__ } }
if ($code -eq 403) { Pass "SQLi sur /api -> 403 (ModSecurity BLOQUE)" } else { Warn "SQLi code=$code (attendu 403 - verifier engine/CRS)" }

$code2 = 0
try { $x = Invoke-WebRequest -Uri "http://localhost/api/iot/latest" -Headers @{ 'User-Agent' = 'sqlmap/1.7' } -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop; $code2 = [int]$x.StatusCode } catch { if ($_.Exception.Response) { $code2 = [int]$_.Exception.Response.StatusCode.value__ } }
if ($code2 -eq 403) { Pass "scanner sqlmap -> 403 (BLOQUE)" } else { Warn "scanner code=$code2 (attendu 403)" }

$dropc = (docker exec ecotrack-suricata sh -c "grep -c '^drop ' /etc/suricata/rules/ecotrack.rules" 2>&1) -join ''
$dn = 0; if (($dropc.Trim()) -match '^\d+$') { $dn = [int]$dropc.Trim() }
if ($dn -ge 3) { Pass "Suricata: $dn regles 'drop' chargees (IPS-ready)" } else { Warn "Suricata drop rules: $dn (attendu >=3)" }
$smode = (docker inspect ecotrack-suricata --format '{{.Config.Cmd}}' 2>&1) -join ''
if ($smode -match '-q ') { Pass "Suricata mode NFQUEUE inline (IPS actif - drop applique)" }
else { Warn "Suricata en af-packet IDS: drop=alerte seulement (IPS inline indispo sur WSL2, ModSec assure le blocage L7)" }


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

# --- 13. VPN enforcement: les UIs admin NE doivent PAS repondre sur l'hote ---
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

# --- Summary ---
Write-Host ""
Write-Host ("RESULT  PASS={0}  WARN={1}  FAIL={2}" -f $script:pass, $script:warn, $script:fail) -ForegroundColor White
if ($script:fail -gt 0) { Write-Host "Status: FAILURES present" -ForegroundColor Red; exit 1 }
elseif ($script:warn -gt 0) { Write-Host "Status: OK with warnings (re-run after warm-up; Wazuh is slowest)" -ForegroundColor Yellow; exit 0 }
else { Write-Host "Status: ALL GREEN" -ForegroundColor Green; exit 0 }