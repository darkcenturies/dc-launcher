#!/usr/bin/env bash
# Dark Centuries — installer
# Run from inside WSL (dml-arch) after your AzerothCore server is set up

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths (adjust if your setup differs) ──────────────────────
AC_DIR="${AC_DIR:-/home/acore/azerothcore}"
LUA_DIR="$AC_DIR/lua_scripts"
MYSQL_USER="${MYSQL_USER:-acore}"
MYSQL_PASS="${MYSQL_PASS:-acore}"
MYSQL_DB="${MYSQL_DB:-acore_world}"

echo "[Dark Centuries] Installing..."

# ── 1. SQL ────────────────────────────────────────────────────
echo "  → Applying SQL schema..."
mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" < "$SCRIPT_DIR/sql/01_schema.sql"
mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" < "$SCRIPT_DIR/sql/02_zones.sql"
mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" "$MYSQL_DB" < "$SCRIPT_DIR/sql/03_npcs.sql"
echo "     Done."

# ── 2. Lua script ─────────────────────────────────────────────
echo "  → Copying Lua script..."
mkdir -p "$LUA_DIR"
cp "$SCRIPT_DIR/lua/dark_centuries.lua" "$LUA_DIR/dark_centuries.lua"
echo "     Copied to $LUA_DIR/dark_centuries.lua"

# ── 3. Client addon ───────────────────────────────────────────
echo ""
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  CLIENT ADDON                                        ║"
echo "  ║  Copy the DarkCenturies/ folder from:               ║"
echo "  ║    dark-centuries/addon/DarkCenturies/               ║"
echo "  ║  to your WoW client:                                 ║"
echo "  ║    WoW/Interface/AddOns/DarkCenturies/               ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo ""

echo "[Dark Centuries] Done. Restart worldserver to activate."
echo "  In-game: open world map to see zone control overlays."
echo "  Slash command: /dc status"
