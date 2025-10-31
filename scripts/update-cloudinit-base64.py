#!/usr/bin/env python3
"""Update cloud-init base64 in azuredeploy.json"""

import base64
import json
import sys

# Read cloud-init YAML files
with open('cloudinit/cloud-init-no-heredoc-v2.yaml', 'rb') as f:
    cloudinit_b64 = base64.b64encode(f.read()).decode('utf-8')

with open('cloudinit/pgbouncer-cloud-init-noheredoc.yaml', 'rb') as f:
    pgbcloudinit_b64 = base64.b64encode(f.read()).decode('utf-8')

# Read azuredeploy.json
with open('azuredeploy.json', 'r', encoding='utf-8') as f:
    template = json.load(f)

# Update variables
template['variables']['cloudInitScript'] = cloudinit_b64
template['variables']['pgbCloudInitScript'] = pgbcloudinit_b64

# Write back
with open('azuredeploy.json', 'w', encoding='utf-8') as f:
    json.dump(template, f, indent=2, ensure_ascii=False)

print("Updated cloudInitScript and pgbCloudInitScript in azuredeploy.json")

