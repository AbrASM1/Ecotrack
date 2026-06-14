# Guide d'utilisation — ECOTRACK

Plateforme de supervision de bacs à déchets connectés, avec sécurité intégrée : WAF, IDS, SIEM et VPN.

## 1. Utilisation générale

La plateforme tourne avec Docker. Deux types d'accès :

- **Public** : l'application web, accessible directement dans le navigateur.
- **Administration** : Grafana, Wazuh, Prometheus, Alertmanager. Ces interfaces ne répondent que si le tunnel VPN WireGuard est actif.

Commandes de base, à lancer dans le dossier du projet :

```powershell
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d   # demarrer
docker compose ps                                                       # etat des conteneurs
docker compose logs -f <service>                                        # suivre les logs
docker compose down                                                     # arret, donnees conservees
```

Active ton tunnel WireGuard avant d'ouvrir une interface d'administration. Sans le tunnel, ces adresses ne répondent pas. Ce comportement est voulu.

## 2. Installation de l'hôte

À faire une seule fois, sur une machine Windows avec Docker Desktop et WSL2.

1. Ouvre **PowerShell en administrateur**. L'étape suivante modifie le fichier hosts et le magasin de certificats, ce qui exige les droits d'administration.
2. Place-toi dans le dossier du projet et lance le script de préparation :

```powershell
powershell -ExecutionPolicy Bypass -File .\prepare-host.ps1
```

Le script enregistre `ecotrack.local` dans le fichier hosts, installe l'autorité de certificat locale mkcert et génère le certificat du WAF dans `.\certs\`.

3. Démarre la stack avec le certificat :

```powershell
docker compose --profile setup run --rm wazuh-certs-generator
docker run --rm -v "${PWD}/wazuh-certs:/certs" alpine sh -c "chmod 644 /certs/*.pem; chown -R 1000:1000 /certs"
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Pour réverter les modifications de l'hôte en fin de projet :

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup-host.ps1
```

## 3. Collecte SIEM : deux modes au choix

Filebeat reste présent dans les deux cas. Tu choisis le mode au démarrage.

### Mode agentless, par défaut

Le manager Wazuh lit directement les journaux du WAF, de ModSecurity et de Suricata, et applique ses règles. Aucun agent à installer.

```powershell
docker compose up -d
```

Mode le plus simple : collecte centralisée, images légères.

### Mode agent

On ajoute un agent Wazuh qui s'enrôle auprès du manager. Il apporte ce que l'agentless ne fait pas : surveillance d'intégrité des fichiers sur les règles de sécurité, réponse active et évaluation de configuration.

```powershell
docker compose -f docker-compose.yml -f docker-compose.agent.yml up -d
```

Mode orienté sécurité de l'endpoint : il détecte une modification de tes règles WAF ou IDS. L'agent apparaît ensuite dans Wazuh, menu **Agents**.

Les deux modes se combinent avec le certificat TLS en ajoutant `-f docker-compose.tls.yml`.

## 4. Accès aux interfaces

Active le VPN WireGuard avant d'ouvrir une interface d'administration.

| Interface | Accès | Adresse | Identifiants |
|-----------|-------|---------|--------------|
| Application | Public | `https://ecotrack.local` | — |
| Dashboard live des bacs | Public | `https://ecotrack.local/dashboard` | — |
| Grafana, KPI déchets | VPN | `http://172.20.4.50:3000` | admin / ecotrack_grafana_pwd |
| Wazuh, console SOC | VPN | `https://172.20.4.30:5601` | admin / SecretPassword |
| Prometheus | VPN | `http://172.20.4.40:9090` | — |
| Alertmanager | VPN | `http://172.20.4.60:9093` | — |

Les identifiants ci-dessus sont des valeurs de démonstration. En production, ils doivent être changés.

## 5. Vérification et tests

État de la flotte et de l'ingestion :

```powershell
docker exec ecotrack-postgres psql -U ecotrack -d ecotrack -tAc "SELECT count(*) FROM iot_readings WHERE recorded_at > NOW() - INTERVAL '2 minutes'"
```

Le compteur doit augmenter d'un appel à l'autre.

Tester une injection SQL. La réponse doit être 403 :

```powershell
curl.exe -sk "https://ecotrack.local/api/iot?id=1%27%20OR%20%271%27=%271" -o NUL -w "code=%{http_code}`n"
```

Vérifier le blocage côté WAF, le compteur doit augmenter après l'attaque :

```powershell
docker exec ecotrack-nginx-waf sh -c "grep -c 9000001 /var/log/nginx/modsec_audit.log"
```

Vérifier l'alerte côté Wazuh, après une quinzaine de secondes :

```powershell
docker exec ecotrack-wazuh-manager sh -c "grep -E '100112|100114|100115' /var/ossec/logs/alerts/alerts.json | tail -3"
```

Vérifier la détection Suricata, le nombre doit être supérieur à zéro :

```powershell
docker exec ecotrack-suricata sh -c "grep -c 'event_type.:.alert' /var/log/suricata/eve.json"
```

Tester une alerte live. Coupe un service, attends environ trois minutes, observe la notification :

```powershell
docker stop ecotrack-cadvisor
Start-Sleep 180
docker logs --tail 30 ecotrack-webhook-logger
docker start ecotrack-cadvisor
```

Tester l'intégrité des fichiers en mode agent. Modifie une règle, relance l'agent, cherche l'alerte :

```powershell
Add-Content .\modsec\REQUEST-900-CUSTOM-SQLI.conf "`n# test FIM"
docker exec ecotrack-wazuh-agent /var/ossec/bin/wazuh-control restart
Start-Sleep 20
docker exec ecotrack-wazuh-manager sh -c "grep -E 'syscheck|ecotrack-config' /var/ossec/logs/alerts/alerts.json | tail -3"
```

Lancer la campagne complète, tunnel actif, durée d'environ dix à quinze minutes :

```powershell
powershell -ExecutionPolicy Bypass -File .\test-ecotrack.ps1
```

## 6. Dépannage du VPN

Si une interface d'administration ne répond pas, le tunnel n'est pas monté. Vérifie dans l'ordre.

Le conteneur tourne et le port est publié :

```powershell
docker ps --filter name=ecotrack-wireguard --format "{{.Status}} {{.Ports}}"
```

Tu dois voir `Up` et `0.0.0.0:51820->51820/udp`.

Erreur `access permissions` au démarrage du conteneur. Windows a réservé le port 51820 après un redémarrage. En PowerShell administrateur :

```powershell
net stop winnat
net start winnat
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d wireguard
```

Le tunnel est monté côté serveur. La ligne `latest handshake` doit être récente et le transfert non nul :

```powershell
docker exec ecotrack-wireguard wg show
```

Côté client Windows, la configuration dérive de `peer1.conf` avec trois ajustements : retirer `ListenPort` du bloc `[Interface]`, fixer `Endpoint` sur la passerelle WSL `172.26.0.1:51820`, ajouter `PersistentKeepalive = 25`. L'adresse de la passerelle WSL peut changer après un redémarrage :

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match "WSL|vEthernet" } | Select-Object InterfaceAlias, IPAddress
```