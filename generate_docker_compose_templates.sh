#!/usr/bin/env bash
set -euo pipefail

OUTDIR="./generated_compose"
mkdir -p "$OUTDIR"

# web (DMZ) compose
cat > "$OUTDIR/docker-compose.web.yml" <<'YML'
version: '3.8'
services:
  web:
    image: your-org/your-web-app:latest
    user: "1000:1000"               # run as non-root inside container
    read_only: true                 # make root filesystem read-only
    tmpfs:
      - /tmp                        # writable tmp only
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
      - seccomp:./web_seccomp.json
    environment:
      - INTERNAL_API_URL=https://10.10.0.11:8443
    ports:
      - "443:443"
YML

# minimal seccomp file for demo (adjust as needed)
cat > "$OUTDIR/web_seccomp.json" <<'JSON'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "syscalls": [
    {
      "names": ["read","write","close","fstat","poll","recvfrom","sendto","sendmsg","recvmsg","nanosleep","clock_gettime","gettimeofday","epoll_wait"],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
JSON

# internal compose (internal vm)
cat > "$OUTDIR/docker-compose.internal.yml" <<'YML'
version: '3.8'
services:
  vault-agent:
    image: hashicorp/vault:latest
    command: agent -config=/vault/config/agent.hcl
    volumes:
      - ./vault-config:/vault/config

  internal-service:
    image: your-org/internal-service:latest
    environment:
      - VAULT_ADDR=http://127.0.0.1:8200
      - DB_DSN=postgresql://app:password@10.10.0.21:5432/appdb
    tmpfs:
      - /run/secrets
YML

echo "Generated compose files in $OUTDIR"
