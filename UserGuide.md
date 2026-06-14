# Guide d'utilisation — ECOTRACK

Plateforme de supervision de bacs à déchets connectés, avec sécurité intégrée (WAF, IDS, SIEM, VPN).

## 1. Guide d'utilisation général

La plateforme tourne avec Docker. Deux types d'accès :

- **Public** : l'application web, accessible directement dans le navigateur.
- **Administration** : Grafana, Wazuh, Prometheus, Alertmanager. Ces interfaces ne sont accessibles que si le tunnel VPN WireGuard est actif.

Avant d'accéder aux interfaces d'administration, active ton tunnel WireGuard. Sans lui, ces adresses ne répondent pas (c'est voulu).

## 2. Installation (préparation de l'hôte)

À faire une seule fois, sur une machine Windows avec Docker Desktop et WSL2.

1. Ouvre **PowerShell en administrateur** (l'étape suivante modifie le fichier hosts et le magasin de certificats).
2. Place-toi dans le dossier du projet et lance :

```powershell
powershell -ExecutionPolicy Bypass -File .\prepare-host.ps1
```

Ce script ajoute `ecotrack.local` au fichier hosts, installe l'autorité de certificat locale (mkcert) et génère le certificat du WAF dans `.\certs\`.

3. Démarre la stack avec le certificat :

```powershell
docker compose --profile setup run --rm wazuh-certs-generator
docker run --rm -v "${PWD}/wazuh-certs:/certs" alpine sh -c "chmod 644 /certs/*.pem; chown -R 1000:1000 /certs"
docker compose -f docker-compose.yml -f docker-compose.tls.yml up -d
```

Pour tout annuler à la fin du projet (hosts, certificat) :

```powershell
powershell -ExecutionPolicy Bypass -File .\cleanup-host.ps1
```

## 3. Collecte SIEM : deux modes au choix

Filebeat reste présent dans les deux cas. Tu choisis le mode au démarrage.

### Mode Agentless (par défaut)

Le manager Wazuh lit directement les journaux du WAF, de ModSecurity et de Suricata, et applique ses règles. Aucun agent à installer.

```powershell
docker compose up -d
```

À utiliser si tu veux le plus simple : collecte centralisée, images légères.

### Mode Agent

On ajoute un agent Wazuh qui s'enrôle auprès du manager. Il apporte ce que le mode agentless ne fait pas : surveillance d'intégrité des fichiers (FIM) sur les règles de sécurité, réponse active et évaluation de configuration.

```powershell
docker compose -f docker-compose.yml -f docker-compose.agent.yml up -d
```

À utiliser si tu veux la sécurité de l'endpoint (détecter une modification de tes règles WAF/IDS). L'agent apparaît ensuite dans Wazuh, menu **Agents**.

Les deux modes peuvent se combiner avec le certificat TLS en ajoutant `-f docker-compose.tls.yml`.

## 4. Accès aux interfaces

Active le VPN WireGuard avant d'ouvrir les interfaces d'administration.

| Interface | Accès | Adresse | Identifiants |
|-----------|-------|---------|--------------|
| Application | Public | `https://ecotrack.local` | — |
| Dashboard live des bacs | Public | `https://ecotrack.local/dashboard` | — |
| Grafana (KPI déchets) | VPN | `http://172.20.4.50:3000` | admin / ecotrack_grafana_pwd |
| Wazuh (SOC) | VPN | `https://172.20.4.30:5601` | admin / SecretPassword |
| Prometheus (métriques) | VPN | `http://172.20.4.40:9090` | — |
| Alertmanager (alertes) | VPN | `http://172.20.4.60:9093` | — |
| CadVisor | VPN | `http://172.20.4.80:8080/` | — |

