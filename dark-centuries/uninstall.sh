#!/usr/bin/env bash
# Dark Centuries — uninstaller
# curl -fsSL <url>/dark-centuries/uninstall.sh | bash

set -e

BASE_RAW="https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/dark-centuries"

AC_DIR="${AC_DIR:-/home/acore/azerothcore}"
LUA_DIR="$AC_DIR/lua_scripts"
MYSQL_USER="${MYSQL_USER:-acore}"
MYSQL_PASS="${MYSQL_PASS:-acore}"
MYSQL_DB="${MYSQL_DB:-acore_world}"

echo "[Dark Centuries] Uninstalling..."

# ── 1. Remove Lua script ──────────────────────────────────────
if [ -f "$LUA_DIR/dark_centuries.lua" ]; then
    rm -f "$LUA_DIR/dark_centuries.lua"
    echo "  → Removed $LUA_DIR/dark_centuries.lua"
else
    echo "  → Lua script not found (already removed?)"
fi

# ── 2. Remove SQL data ────────────────────────────────────────
echo "  → Removing SQL data..."
mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" <<'SQL'
DELETE FROM smart_scripts WHERE entryorguid IN (900001, 900002) AND source_type = 0;
DELETE FROM creature_template WHERE entry IN (900001, 900002);
DELETE FROM creature WHERE id IN (900001, 900002);
DROP TABLE IF EXISTS dc_zone_control;
SQL
echo "     Done."

echo ""
echo "[Dark Centuries] Uninstalled. Restart worldserver to apply."
echo "  Remove WoW/Interface/AddOns/DarkCenturies/ from your WoW client manually."
