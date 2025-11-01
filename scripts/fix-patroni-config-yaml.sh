#!/bin/bash
# Fix Patroni config YAML syntax errors

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
  
  # Check if config has YAML errors
  yaml_error=$(ssh_cmd "$host" "sudo python3 -c \"import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))\" 2>&1" || echo "error")
  
  if echo "$yaml_error" | grep -q "error\|Error\|Traceback"; then
    say "YAML syntax error detected, fixing..."
    
    # Show error details
    say "Error details:"
    ssh_cmd "$host" "sudo python3 -c \"import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))\" 2>&1 | head -10" || true
    
    # Check for common issues around line 21
    say "Checking around line 21:"
    ssh_cmd "$host" "sudo sed -n '15,25p' /etc/patroni/patroni.yml"
    
    # Restore from backup or fix manually
    say "Attempting to restore from backup..."
    backup_file=$(ssh_cmd "$host" "sudo ls -t /etc/patroni/patroni.yml.backup.* 2>/dev/null | head -1" || echo "")
    
    if [[ -n "$backup_file" ]]; then
      say "Restoring from: $backup_file"
      ssh_cmd "$host" "sudo cp '$backup_file' /etc/patroni/patroni.yml"
      
      # Verify restore worked
      if ssh_cmd "$host" "sudo python3 -c \"import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))\" 2>&1" >/dev/null; then
        say "✓ Config restored successfully"
      else
        say "✗ Restore failed, config still has errors"
      fi
    else
      say "No backup found, attempting manual fix..."
      # Remove problematic lines (duplicate parameters or syntax issues)
      ssh_cmd "$host" "sudo bash" <<'BASH'
# Backup current
cp /etc/patroni/patroni.yml /etc/patroni/patroni.yml.broken.$(date +%s)

# Remove duplicate max_connections lines (keep only one)
# Find line with max_connections and remove duplicates
sed -i '/^[[:space:]]*max_connections:/d' /etc/patroni/patroni.yml

# Try to fix indentation issues around parameters
# This is a simple fix - may need manual intervention
python3 <<'PYTHON'
import re

with open('/etc/patroni/patroni.yml', 'r') as f:
    lines = f.readlines()

# Find and fix parameters section
fixed = []
in_params = False
indent_level = 0

for i, line in enumerate(lines):
    # Detect parameters section
    if 'parameters:' in line and not line.strip().startswith('#'):
        in_params = True
        indent_level = len(line) - len(line.lstrip())
        fixed.append(line)
        # Add max_connections with correct indentation
        fixed.append(' ' * (indent_level + 2) + 'max_connections: 500\n')
        continue
    
    # Skip old max_connections lines
    if 'max_connections:' in line:
        continue
    
    fixed.append(line)

with open('/etc/patroni/patroni.yml', 'w') as f:
    f.writelines(fixed)
PYTHON
BASH
    fi
    
    # Verify fix
    say "Verifying YAML syntax..."
    if ssh_cmd "$host" "sudo python3 -c \"import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))\" 2>&1" >/dev/null; then
      say "✓ YAML syntax is now valid"
    else
      say "✗ YAML syntax still has errors - manual intervention needed"
      say "Check config: sudo cat /etc/patroni/patroni.yml"
    fi
    
    # Start Patroni if config is fixed
    if ssh_cmd "$host" "sudo python3 -c \"import yaml; yaml.safe_load(open('/etc/patroni/patroni.yml'))\" 2>&1" >/dev/null; then
      say "Starting Patroni..."
      ssh_cmd "$host" "sudo systemctl start patroni"
      sleep 5
      say "Patroni status:"
      ssh_cmd "$host" "sudo systemctl status patroni --no-pager | head -5"
    fi
  else
    say "✓ YAML syntax is valid"
  fi
  
  echo ""
done

