# Updating HA custom sentences / intent config

Before making any changes to the custom sentences or `intent_script`, always read
the current state from the Pi first — do not rely on memory or local copies.

**Step 1 — Read existing intent files from Pi:**
```bash
ssh hailo-pi 'cat /home/ctf/homeassistant/config/custom_sentences/en/lights.yaml'
ssh hailo-pi 'cat /home/ctf/homeassistant/config/custom_sentences/en/shades.yaml'
ssh hailo-pi 'cat /home/ctf/homeassistant/config/custom_sentences/en/heat_pump.yaml'
ssh hailo-pi 'grep -A 20 "intent_script:" /home/ctf/homeassistant/config/configuration.yaml'
```

**Step 2 — List all exposed HA entities:**
```bash
ssh hailo-pi "python3 -c \"
import json
with open('/home/ctf/homeassistant/config/.storage/core.entity_registry') as f:
    reg = json.load(f)
exposed = [e for e in reg['data']['entities']
           if e.get('options', {}).get('conversation', {}).get('should_expose')]
for e in exposed:
    print(e['entity_id'], '|', e.get('name') or e.get('original_name', ''))
\""
```

For scenes specifically (friendly names are what `HassTurnOn` slots match against):
```bash
ssh hailo-pi "python3 -c \"
import json
with open('/home/ctf/homeassistant/config/.storage/core.entity_registry') as f:
    reg = json.load(f)
for e in reg['data']['entities']:
    if e['entity_id'].startswith('scene.'):
        print(e['entity_id'], '|', e.get('name') or e.get('original_name', ''))
\""
```

**Step 3 — After editing, validate YAML and restart HA:**
```bash
# Validate syntax before deploying
ssh hailo-pi 'python3 -c "import yaml; yaml.safe_load(open(\"/path/to/file\"))" && echo OK'

# Restart HA and check logs for config errors
ssh hailo-pi 'cd ~/homeassistant && docker compose restart homeassistant'
ssh hailo-pi 'sleep 15 && docker logs homeassistant 2>&1 | grep -iE "(error|intent|custom_sentence)" | tail -20'
```

**Key rules for custom sentences:**
- `HassTurnOn` / `HassTurnOff` / `HassLightSet` are built-in HA intents — no `intent_script` needed
- Custom intent names (like `HeatPumpSource`) require a matching `intent_script` block in `configuration.yaml`
- `slots:` are per data item (each `-` under `data:`) not per intent
- Scene `name` slots must match the scene's **friendly name** exactly (not entity_id)
- Always cross-check scene friendly names from the entity registry before using them as slots
