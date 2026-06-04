#requires -Version 5.1
# Push par couches vers GitHub, un commit a la fois, avec pause pour le CI.
# A lancer depuis la racine du projet, APRES avoir ajoute la remote 'origin'.

$ErrorActionPreference = 'Stop'
$pause = 90   # secondes entre chaque push (laisse le CI tourner)

function Step($msg){ Write-Host "`n== $msg ==" -ForegroundColor Cyan }

# --- 0. Pre-requis ---
git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "[FAIL] pas un depot git" -ForegroundColor Red; exit 1 }
if (-not (git remote | Select-String '^origin$')) {
    Write-Host "[FAIL] remote 'origin' absente. Fais: git remote add origin <url>" -ForegroundColor Red; exit 1
}

# --- 1. Corriger un eventuel BOM dans .gitignore (Set-Content UTF8 en ajoute un) ---
$gi = ".gitignore"
$bytes = [System.IO.File]::ReadAllBytes($gi)
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $text = [System.IO.File]::ReadAllText($gi)
    [System.IO.File]::WriteAllText($gi, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[OK] BOM retire de .gitignore" -ForegroundColor Green
}

# --- 2. CONTROLE ANTI-FUITE LOCAL (bloquant) ---
Step "Controle anti-fuite"
$leak = git ls-files | Select-String "node_modules|\.pem$|-key\.pem$|peer1|\.key$|\.env$|\.log$"
# (certs/*.pem est ignore; .gitkeep autorise)
$leak = $leak | Where-Object { $_ -notmatch "certs/.gitkeep" }
if ($leak) {
    Write-Host "[FAIL] fichiers sensibles suivis - push annule :" -ForegroundColor Red
    $leak | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
    Write-Host "Detracke-les: git rm -r --cached <chemin> puis relance." -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] aucun fichier sensible suivi" -ForegroundColor Green

# --- 3. S'assurer que la branche distante existe (premier push) ---
$branch = (git rev-parse --abbrev-ref HEAD).Trim()

# Helper : commit d'un ensemble de chemins puis push
function Commit-Push($message, [string[]]$paths){
    $existing = $paths | Where-Object { Test-Path $_ }
    if (-not $existing) { Write-Host "[--] rien a committer pour: $message" -ForegroundColor DarkGray; return }
    git add -- $existing
    $staged = git diff --cached --name-only
    if (-not $staged) { Write-Host "[--] aucun changement: $message" -ForegroundColor DarkGray; return }
    git commit -m $message | Out-Null
    Write-Host "[commit] $message" -ForegroundColor Green
    git push -u origin $branch
    Write-Host "[push] OK - pause $pause s (CI en cours)..." -ForegroundColor Cyan
    Start-Sleep $pause
}

# --- 4. Les couches, dans l'ordre ---
Commit-Push "chore: gitignore (secrets, node_modules, certs, logs)" @(".gitignore")
Commit-Push "feat(core): API ingestion TLS + index dernier releve" @("api/server.js")
Commit-Push "feat(iot): simulateur flotte 2000 + flux TLS via WAF" @("iot-simulator/simulator.py")
Commit-Push "feat(security): flux capteurs TLS + override certificat local" @("docker-compose.tls.yml","certs/.gitkeep","suricata/entrypoint.sh")
Commit-Push "feat(monitoring): datasource PostGIS + dashboard flotte/Geomap" @("grafana/dashboards/ecotrack-overview.json","grafana/provisioning/datasources/datasource.yml")
Commit-Push "feat(alerting): webhook + anomalies dynamiques (z-score, moyennes mobiles)" @("alertmanager/alertmanager.yml","prometheus/rules/ecotrack-alerts.yml")
Commit-Push "feat(siem): pipeline Filebeat multi-sources" @("filebeat/filebeat.yml")
Commit-Push "feat(ops): compose (backup PostgreSQL) + scripts hote" @("docker-compose.yml","prepare-host.ps1","cleanup-host.ps1")
Commit-Push "test+docs: campagne E2E/offensive + README" @("test-ecotrack.ps1","README.md")
Commit-Push "ci(securite): pipeline GitHub Actions (lint, Trivy, anti-fuite)" @(".github/workflows/ci.yml")

# --- 5. Filet de securite : pousser tout reste non commite ---
Step "Verification finale"
if (git status --porcelain) {
    git add -A
    git commit -m "chore: divers" | Out-Null
    git push -u origin $branch
    Write-Host "[push] reliquat pousse" -ForegroundColor Green
} else {
    Write-Host "[OK] arbre de travail propre, tout est pousse" -ForegroundColor Green
}
Write-Host "`nTermine. Onglet Actions de GitHub pour suivre le CI." -ForegroundColor Cyan