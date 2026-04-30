### Routing inter-services Swarm dans LXC privileged : IPVS ne forward pas non plus en interne

Au-delà du problème d'ingress décrit ci-dessus, **le même bug IPVS affecte aussi le trafic inter-services Swarm** sur les overlay networks. Quand un service essaie de joindre un autre service par son nom (DNS Swarm), la résolution renvoie une **VIP (Virtual IP)** qui doit être forwarder via IPVS vers l'IP réelle du container — et ce forwarding échoue silencieusement en LXC.

**Symptômes :**
- Postgres déployé en service Swarm, healthy en local (`docker exec postgres pg_isready` répond OK)
- Un autre service du même overlay essaie de se connecter via `host=postgres` : timeout TCP
- Le DNS résout correctement (`getent hosts postgres` renvoie une IP)
- Le `ping` vers cette IP fonctionne (ICMP)
- Mais `nc -zv postgres 5432` timeout
- En direct sur l'IP réelle du container (pas la VIP), la connexion fonctionne

**Diagnostic reproductible :**

```bash
# Voir l'IP du container vs la VIP du service
docker network inspect <network> --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}'
# Exemple : postgres_postgres.1.xxx : 10.20.2.3/24

docker service inspect <service> --format '{{json .Endpoint}}'
# Exemple : {"Spec":{"Mode":"vip"},"VirtualIPs":[{"Addr":"10.20.2.2/24"}]}

# Tester depuis un autre container
docker run --rm --network <network> alpine sh -c "nc -zv 10.20.2.2 5432"   # VIP : timeout
docker run --rm --network <network> alpine sh -c "nc -zv 10.20.2.3 5432"   # IP reelle : OK
```

**Cause racine :**
Identique à la limitation précédente — IPVS ne fonctionne pas dans un namespace LXC privileged. Cette fois le problème ne touche pas l'ingress port LAN, mais le **service VIP** créé par défaut pour chaque service Swarm sur ses overlay networks.

**Workaround obligatoire : `endpoint_mode: dnsrr` sur tous les services**

Avec le mode DNSRR (DNS Round Robin), Swarm ne crée plus de VIP. Le DNS résout directement vers les IPs des containers du service, sans IPVS dans la chaîne.

```yaml
services:
  postgres:
    image: postgres:16-alpine
    # ...
    deploy:
      mode: replicated
      replicas: 1
      endpoint_mode: dnsrr   # ← OBLIGATOIRE en LXC, sinon timeout TCP
      placement:
        constraints:
          - node.role == manager
```

**Compromis :** avec DNSRR sur un service multi-replicas, le client doit gérer le round-robin lui-même (la plupart des libs HTTP, gRPC, asyncpg le font nativement). Pour `replicas: 1` aucune différence pratique.

**Règle pratique :** **tous** les services Swarm déployés dans ces LXC doivent utiliser `endpoint_mode: dnsrr`. À ajouter dans chaque compose, sans exception. À documenter dans le compose pour le futur (`# OBLIGATOIRE LXC : workaround IPVS`).

**Pour diagnostiquer un nouveau service qui n'arrive pas à joindre un autre :**

```bash
# 1. Verifier le mode du service
docker service inspect <service> --format '{{.Spec.EndpointSpec.Mode}}'
# Si "vip" ou vide -> il faut basculer en dnsrr

# 2. Comparer DNS resolution et IPs reelles
docker run --rm --network <network> alpine sh -c \
    "getent hosts <service_name>; ping -c 2 <service_name>"
docker network inspect <network> --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}'
```

**Vrai fix :** identique — migrer vers une VM. Le mode VIP de Swarm fonctionne correctement en VM.