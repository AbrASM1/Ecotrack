#requires -Version 5.1
# Prepare la machine hote Windows pour le projet ECOTRACK.
# A lancer en PowerShell ADMINISTRATEUR depuis la racine du projet :
#   powershell -ExecutionPolicy Bypass -File .\prepare-host.ps1
# Idempotent : relancable sans effet de bord. Reverter avec cleanup-host.ps1.

$ErrorActionPreference = 'Stop'
Write-Host "== Preparation hote ECOTRACK ==" -ForegroundColor Cyan

# --- 0. Verifier les droits administrateur (hosts + CA l'exigent) ---
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "[FAIL] Ce script doit etre lance en ADMINISTRATEUR (clic droit PowerShell -> Executer en tant qu'administrateur)." -ForegroundColor Red
    exit 1
}

# --- 1. Verifier Docker ---
try {
    docker version --format '{{.Server.Version}}' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
    Write-Host "[OK] Docker est demarre" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Docker n'est pas accessible - lance Docker Desktop puis relance ce script." -ForegroundColor Red
    exit 1
}

# --- 2. Entree hosts : 127.0.0.1 ecotrack.local ---
$hosts = "$env:WINDIR\System32\drivers\etc\hosts"
$content = Get-Content $hosts -ErrorAction SilentlyContinue
if ($content -match '\becotrack\.local\b') {
    Write-Host "[--] hosts : 'ecotrack.local' deja present" -ForegroundColor DarkGray
} else {
    Add-Content -Path $hosts -Value "127.0.0.1 ecotrack.local" -Encoding ASCII
    Write-Host "[OK] hosts : '127.0.0.1 ecotrack.local' ajoute" -ForegroundColor Green
}

# --- 3. mkcert : s'assurer qu'il est disponible ---
$mk = Get-Command mkcert -ErrorAction SilentlyContinue
if (-not $mk) { $mk = Get-Command .\mkcert.exe -ErrorAction SilentlyContinue }
if (-not $mk) {
    Write-Host "[..] mkcert introuvable - telechargement du binaire..." -ForegroundColor DarkGray
    try {
        Invoke-WebRequest -Uri "https://dl.filippo.io/mkcert/latest?for=windows/amd64" -OutFile ".\mkcert.exe"
        $mk = Get-Command .\mkcert.exe
        Write-Host "[OK] mkcert.exe telecharge dans le dossier du projet" -ForegroundColor Green
    } catch {
        Write-Host "[FAIL] telechargement mkcert echoue. Installe-le manuellement (choco install mkcert) puis relance." -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[OK] mkcert disponible : $($mk.Source)" -ForegroundColor Green
}

# --- 4. Installer la CA racine locale mkcert (magasin de confiance) ---
& $mk.Source -install
Write-Host "[OK] CA racine mkcert installee dans le magasin de confiance" -ForegroundColor Green

# --- 5. Generer le certificat pour ecotrack.local dans .\certs\ ---
New-Item -ItemType Directory -Force -Path ".\certs" | Out-Null
if ((Test-Path ".\certs\ecotrack.local.pem") -and (Test-Path ".\certs\ecotrack.local-key.pem") `
    -and ((Get-Item ".\certs\ecotrack.local.pem").PSIsContainer -eq $false)) {
    Write-Host "[--] certificat .\certs\ecotrack.local.pem deja present" -ForegroundColor DarkGray
} else {
    # nettoyer d'eventuels dossiers parasites crees par un montage Docker premature
    foreach ($p in @(".\certs\ecotrack.local.pem", ".\certs\ecotrack.local-key.pem")) {
        if ((Test-Path $p) -and (Get-Item $p).PSIsContainer) { Remove-Item $p -Recurse -Force }
    }
    & $mk.Source -cert-file ".\certs\ecotrack.local.pem" -key-file ".\certs\ecotrack.local-key.pem" ecotrack.local
    Write-Host "[OK] certificat genere : .\certs\ecotrack.local.pem (+ cle)" -ForegroundColor Green
}

# --- 6. Verifications ---
$certOk = (Test-Path ".\certs\ecotrack.local.pem") -and ((Get-Item ".\certs\ecotrack.local.pem").Length -gt 0) `
          -and ((Get-Item ".\certs\ecotrack.local.pem").PSIsContainer -eq $false)
$hostsOk = (Get-Content $hosts) -match '\becotrack\.local\b'
Write-Host ""
Write-Host "Resume :" -ForegroundColor Cyan
Write-Host ("  hosts ecotrack.local : {0}" -f ($(if ($hostsOk) {'OK'} else {'MANQUANT'})))
Write-Host ("  certificat TLS       : {0}" -f ($(if ($certOk)  {'OK'} else {'MANQUANT'})))
Write-Host ""

if ($certOk -and $hostsOk) {
    Write-Host "Hote pret. Demarrer le projet :" -ForegroundColor Green
    Write-Host '  docker compose --profile setup run --rm wazuh-certs-generator' -ForegroundColor White
    Write-Host '  docker run --rm -v "${PWD}/wazuh-certs:/certs" alpine sh -c "chmod 644 /certs/*.pem; chown -R 1000:1000 /certs"' -ForegroundColor White
    Write-Host '  docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d' -ForegroundColor White
} else {
    Write-Host "Preparation incomplete - voir les lignes [FAIL] ci-dessus." -ForegroundColor Yellow
}