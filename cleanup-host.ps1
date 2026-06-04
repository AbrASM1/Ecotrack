#requires -Version 5.1
# Annule les modifications faites au SYSTEME hote par le projet ECOTRACK.
# A lancer en PowerShell ADMINISTRATEUR, une fois le projet termine.
# N'affecte PAS les conteneurs/volumes Docker (voir la section Docker plus bas).

Write-Host "== Nettoyage hote ECOTRACK ==" -ForegroundColor Cyan

# --- 1. Entree hosts : 127.0.0.1 ecotrack.local ---
$hosts = "$env:WINDIR\System32\drivers\etc\hosts"
try {
    $lines = Get-Content $hosts -ErrorAction Stop
    $filtered = $lines | Where-Object { $_ -notmatch '\becotrack\.local\b' }
    if ($lines.Count -ne $filtered.Count) {
        Set-Content -Path $hosts -Value $filtered -Encoding ASCII
        Write-Host "[OK] entree 'ecotrack.local' retiree du fichier hosts" -ForegroundColor Green
    } else {
        Write-Host "[--] aucune entree 'ecotrack.local' dans hosts" -ForegroundColor DarkGray
    }
} catch {
    Write-Host "[FAIL] hosts non modifiable - lance ce script en ADMINISTRATEUR" -ForegroundColor Red
}

# --- 2. Certificats locaux generes (fichiers .pem du projet) ---
if (Test-Path ".\certs\ecotrack.local.pem")     { Remove-Item ".\certs\ecotrack.local.pem" -Force }
if (Test-Path ".\certs\ecotrack.local-key.pem") { Remove-Item ".\certs\ecotrack.local-key.pem" -Force }
Write-Host "[OK] certificats .\certs\*.pem supprimes" -ForegroundColor Green

# --- 3. CA racine mkcert (magasin de confiance) ---
# ATTENTION : ne retirer que si mkcert n'est utilise par AUCUN autre projet.
$ans = Read-Host "Retirer la CA racine mkcert du magasin de confiance ? (casse les autres certs mkcert) [o/N]"
if ($ans -eq 'o' -or $ans -eq 'O') {
    $mk = Get-Command mkcert -ErrorAction SilentlyContinue
    if (-not $mk) { $mk = Get-Command .\mkcert.exe -ErrorAction SilentlyContinue }
    if ($mk) {
        & $mk.Source -uninstall
        Write-Host "[OK] CA racine mkcert retiree (mkcert -uninstall)" -ForegroundColor Green
    } else {
        Write-Host "[--] binaire mkcert introuvable - desinstallation CA ignoree" -ForegroundColor Yellow
        Write-Host "     (sinon, supprime manuellement la CA 'mkcert development CA' via certmgr.msc)" -ForegroundColor DarkGray
    }
} else {
    Write-Host "[--] CA mkcert conservee (choix utilisateur)" -ForegroundColor DarkGray
}

# --- 4. Flush DNS pour purger le cache de resolution ---
ipconfig /flushdns | Out-Null
Write-Host "[OK] cache DNS vide" -ForegroundColor Green

Write-Host ""
Write-Host "Termine. Pour l'environnement Docker, voir les commandes ci-dessous (a lancer separement)." -ForegroundColor Cyan