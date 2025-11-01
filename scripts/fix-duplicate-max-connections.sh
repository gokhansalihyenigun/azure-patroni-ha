#!/bin/bash
# Remove duplicate max_connections from Patroni config

set -eo pipefail

DB_NODES=(10.50.1.4 10.50.1.5)
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-Azure123!@#}"

say() { echo "[FIX] $*"; }

ssh_cmd() {
  local host="$1"
  shift
  sshpass -p "$ADMIN_PASS" ssh -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "${ADMIN_USER}@${host}" "$@" 2>/dev/null || return 1
}

for host in "${DB_NODES[@]}"; do
  say "=== Fixing $host ==="
  
  ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup
cp /etc/patroni/patroni.yml /etc/patroni/patroni.yml.fix.$(date +%s) 2>/dev/null || true

# Use Python to safely remove duplicates and fix YAML
python3 <<'PYTHON'
import yaml
import sys

try:
    with open('/etc/patroni/patroni.yml', 'r') as f:
        content = f.read()
    
    # Try to load YAML - if it fails, manually fix
    try:
        config = yaml.safe_load(content)
    except yaml.YAMLError as e:
        print(f"YAML parse error: {e}")
        # Manual fix: remove duplicate max_connections lines
        lines = content.split('\n')
        fixed = []
        max_conn_count = 0
        
        for line in lines:
            stripped = line.strip()
            # Count max_connections occurrences
            if 'max_connections:' in stripped and not stripped.startswith('#'):
                max_conn_count += 1
                # Keep only the first one (should be in bootstrap.dcs.postgresql.parameters)
                if max_conn_count == 1:
                    fixed.append(line)
                # Skip duplicates (wrong indentation ones)
                elif 'max_connections: 500' in stripped:
                    print(f"Skipping duplicate line: {line}")
                    continue
                else:
                    fixed.append(line)
            else:
                fixed.append(line)
        
        content = '\n'.join(fixed)
        config = yaml.safe_load(content)
    
    # Ensure max_connections is only in the right places
    # Remove all max_connections first
    if 'bootstrap' in config and 'dcs' in config['bootstrap']:
        if 'postgresql' in config['bootstrap']['dcs']:
            if 'parameters' in config['bootstrap']['dcs']['postgresql']:
                if 'max_connections' in config['bootstrap']['dcs']['postgresql']['parameters']:
                    del config['bootstrap']['dcs']['postgresql']['parameters']['max_connections']
    
    if 'postgresql' in config:
        if 'parameters' in config['postgresql']:
            if 'max_connections' in config['postgresql']['parameters']:
                del config['postgresql']['parameters']['max_connections']
    
    # Add max_connections only to postgresql.parameters (runtime)
    if 'postgresql' not in config:
        config['postgresql'] = {}
    if 'parameters' not in config['postgresql']:
        config['postgresql']['parameters'] = {}
    
    config['postgresql']['parameters']['max_connections'] = 500
    
    # Write back
    with open('/etc/patroni/patroni.yml', 'w') as f:
        yaml.dump(config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    
    # Verify
    with open('/etc/patroni/patroni.yml', 'r') as f:
        yaml.safe_load(f)
    
    print("✓ Config fixed successfully")
    
except Exception as e:
    print(f"✗ Error: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
PYTHON

# Verify YAML is valid
python3 -c "import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))" && echo "✓ YAML valid" || echo "✗ YAML invalid!"

# Show max_connections occurrences
echo "max_connections occurrences:"
grep -n "max_connections" /etc/patroni/patroni.yml || echo "  (not found)"

BASH
  
  if [[ $? -eq 0 ]]; then
    # Start Patroni
    say "Starting Patroni..."
    ssh_cmd "$host" "sudo systemctl start patroni"
    sleep 10
    
    # Check status
    say "Patroni status:"
    ssh_cmd "$host" "sudo systemctl status patroni --no-pager | head -8" || true
  fi
  
  echo ""
done

