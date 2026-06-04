#!/bin/sh
set -e

ET_DIR=/var/lib/suricata/rules
ET_RULES="$ET_DIR/suricata.rules"
LOCAL_RULES=/etc/suricata/rules/ecotrack.rules
COMBINED=/var/lib/suricata/rules/ecotrack-combined.rules
mkdir -p "$ET_DIR"

echo "[suricata] suricata-update: telechargement Emerging Threats Open..."
if suricata-update --no-test -o "$ET_DIR" >/tmp/su.log 2>&1; then
  echo "[suricata] ET Open ecrit ($(grep -c . "$ET_RULES" 2>/dev/null || echo 0) lignes)"
else
  echo "[suricata] AVERTISSEMENT: suricata-update KO (voir /tmp/su.log)"
fi

cat "$LOCAL_RULES" > "$COMBINED"
if [ -s "$ET_RULES" ]; then
  echo "" >> "$COMBINED"
  cat "$ET_RULES" >> "$COMBINED"
fi
echo "[suricata] jeu combine: $(grep -c . "$COMBINED" 2>/dev/null || echo 0) lignes (local + ET Open)"

exec suricata -i eth0 -k none -S "$COMBINED" -v