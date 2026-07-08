#!/usr/bin/env bash
# ============================================================
#  Dark Centuries — Zone Control Warfare installer
#  For DC Launcher WotLK servers (AzerothCore + Docker + ALE/Eluna)
#
#  Non-interactive; safe to pipe:
#    curl -fsSL .../dark-centuries/install.sh | bash
#
#  What it does:
#    1. Finds your WotLK server install (SERVER_DIR)
#    2. Starts the ac-database container if needed
#    3. Applies SQL via docker exec (custom tables — not AC-tracked,
#       so direct apply is safe and won't break db-import)
#    4. Deploys dark_centuries.lua to the ALE lua_scripts directory
#    5. Copies the client addon into your WoW client if found
# ============================================================

set -o pipefail

BASE_RAW="https://raw.githubusercontent.com/darkcenturies/dc-launcher/main/dark-centuries"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-password}"   # acore-docker default

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
info() { echo -e "  ${CYAN}[..]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; exit 1; }

echo ""
echo "=== Dark Centuries — Zone Control Warfare ==="
echo ""

# ── 1. Locate server install ─────────────────────────────────
SERVER_DIR=""
for candidate in "$HOME/games/wow-server-playerbots" "$HOME/wow-server-playerbots" "$HOME"/games/*/; do
    if [ -f "$candidate/docker-compose.yml" ] || [ -d "$candidate/env/dist/etc" ]; then
        SERVER_DIR="${candidate%/}"
        break
    fi
done
[ -n "$SERVER_DIR" ] || fail "No WotLK server install found. Install the WotLK server first (DC Launcher > Extras > Install New Title)."
ok "Server: $SERVER_DIR"

# ── 2. ALE/Eluna Lua engine check ────────────────────────────
LUA_DIR="$SERVER_DIR/env/dist/etc/modules/lua_scripts"
if [ ! -d "$LUA_DIR" ]; then
    warn "ALE lua_scripts directory not found — the Lua engine (mod-ale) may not be installed."
    warn "Install an ALE-Kegs Lua mod first via wow-manage.sh, or the script won't load."
    mkdir -p "$LUA_DIR" || fail "Could not create $LUA_DIR"
fi

# ── 3. Database container ────────────────────────────────────
# ── Docker availability ──────────────────────────────────────
# Group membership may not be active in this shell; daemon may be stopped.
if ! docker ps >/dev/null 2>&1; then
    if sudo -n docker ps >/dev/null 2>&1 || sudo docker ps >/dev/null 2>&1; then
        docker() { sudo /usr/bin/docker "$@"; }
        info "Using sudo for docker"
    else
        info "Docker daemon not running — starting it (may ask for your password)..."
        sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null
        sleep 3
        if docker ps >/dev/null 2>&1; then
            :
        elif sudo docker ps >/dev/null 2>&1; then
            docker() { sudo /usr/bin/docker "$@"; }
        else
            fail "Docker is not available. Start your server once via DC Launcher first."
        fi
    fi
fi

DB_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'ac-database|wow.*database' | head -1)
if [ -z "$DB_CONTAINER" ]; then
    info "Database container not found — creating it via docker compose..."
    (cd "$SERVER_DIR" && docker compose up -d ac-database >/dev/null 2>&1) || true
    sleep 2
    DB_CONTAINER=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -iE 'ac-database|wow.*database' | head -1)
fi
[ -n "$DB_CONTAINER" ] || fail "Could not find or create the database container. Start your server once via DC Launcher first."

if ! docker ps --format '{{.Names}}' | grep -q "^$DB_CONTAINER$"; then
    info "Starting database container..."
    (cd "$SERVER_DIR" && docker compose up -d ac-database >/dev/null 2>&1) || true
fi
for i in $(seq 1 15); do
    if docker exec "$DB_CONTAINER" mysqladmin ping -uroot -p"$DB_ROOT_PASSWORD" >/dev/null 2>&1; then
        break
    fi
    [ "$i" = 15 ] && fail "Database did not become ready."
    sleep 2
done
ok "Database: $DB_CONTAINER"

# ── 4. Apply SQL ─────────────────────────────────────────────
for f in 01_schema.sql 02_zones.sql 03_npcs.sql; do
    info "Applying $f..."
    if curl -fsSL "$BASE_RAW/sql/$f" | docker exec -i "$DB_CONTAINER" mysql -uroot -p"$DB_ROOT_PASSWORD" acore_world 2>/dev/null; then
        ok "$f applied"
    else
        fail "SQL apply failed: $f"
    fi
done

# ── 5. Deploy Lua script ─────────────────────────────────────
info "Deploying dark_centuries.lua..."
curl -fsSL "$BASE_RAW/lua/dark_centuries.lua" -o "$LUA_DIR/dark_centuries.lua" \
    || fail "Download failed: dark_centuries.lua"
ok "Deployed to $LUA_DIR/dark_centuries.lua"

# ── 6. Client addon (best effort) ────────────────────────────
WOW_CLIENT_DIR=""
for base in /mnt/c /mnt/d; do
    for p in "$base/Games/World of Warcraft 3.3.5a" "$base/Games/WoW-3.3.5a" \
             "$base/WoW" "$base/Games/WoW" "$base"/Users/*/Desktop/WoW* \
             "$base"/Users/*/Games/WoW*; do
        if [ -f "$p/Wow.exe" ] || [ -f "$p/WoW.exe" ]; then
            WOW_CLIENT_DIR="$p"; break 2
        fi
    done
done

if [ -n "$WOW_CLIENT_DIR" ]; then
    ADDON_DIR="$WOW_CLIENT_DIR/Interface/AddOns/DarkCenturies"
    mkdir -p "$ADDON_DIR"
    curl -fsSL "$BASE_RAW/addon/DarkCenturies/DarkCenturies.toc" -o "$ADDON_DIR/DarkCenturies.toc" && \
    curl -fsSL "$BASE_RAW/addon/DarkCenturies/DarkCenturies.lua" -o "$ADDON_DIR/DarkCenturies.lua" && \
        ok "Client addon installed: $ADDON_DIR" || warn "Client addon download failed — install manually."
else
    warn "WoW client not auto-detected. Install the addon manually:"
    echo "         download dark-centuries/addon/DarkCenturies/ from the repo"
    echo "         into <WoW>/Interface/AddOns/DarkCenturies/"
fi

# ── 7. Done ──────────────────────────────────────────────────
echo ""
ok "Dark Centuries installed."
info "Restart the worldserver to activate:"
echo "         cd $SERVER_DIR && docker compose restart ac-worldserver"
info "In-game: open the world map to see zone control overlays. /dc status for details."
echo ""
