#!/usr/bin/env bash
# Dark Centuries — self-contained installer
# Can be run directly or piped: curl -fsSL <url>/dark-centuries/install.sh | bash

set -e

BASE_RAW="https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/dark-centuries"

# ── Paths (adjust if your setup differs) ──────────────────────
AC_DIR="${AC_DIR:-/home/acore/azerothcore}"
LUA_DIR="$AC_DIR/lua_scripts"
MYSQL_USER="${MYSQL_USER:-acore}"
MYSQL_PASS="${MYSQL_PASS:-acore}"
MYSQL_DB="${MYSQL_DB:-acore_world}"

echo "[Dark Centuries] Installing..."

# ── 1. SQL ────────────────────────────────────────────────────
echo "  → Applying SQL schema..."
curl -fsSL "$BASE_RAW/sql/01_schema.sql" | mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB"
curl -fsSL "$BASE_RAW/sql/02_zones.sql"  | mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB"
curl -fsSL "$BASE_RAW/sql/03_npcs.sql"   | mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB"
echo "     Done."

# ── 2. Lua script ─────────────────────────────────────────────
echo "  → Installing Lua script..."
mkdir -p "$LUA_DIR"
curl -fsSL "$BASE_RAW/lua/dark_centuries.lua" -o "$LUA_DIR/dark_centuries.lua"
echo "     Copied to $LUA_DIR/dark_centuries.lua"

# ── 3. Client addon ───────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  CLIENT ADDON                                        ║"
echo "  ║  Download the DarkCenturies addon folder from:       ║"
echo "  ║    https://github.com/darkcenturies/dc-launcher      ║"
echo "  ║      dark-centuries/addon/DarkCenturies/             ║"
echo "  ║  Copy it to your WoW client:                         ║"
echo "  ║    WoW/Interface/AddOns/DarkCenturies/               ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""

echo "[Dark Centuries] Done. Restart worldserver to activate."
echo "  In-game: open world map to see zone control overlays."
echo "  Slash command: /dc status"
