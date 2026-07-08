#!/usr/bin/env bash
# ============================================================
#  Dark Centuries — uninstaller
#  curl -fsSL .../dark-centuries/uninstall.sh | bash
# ============================================================

set -o pipefail

DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-password}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
info() { echo -e "  ${CYAN}[..]${NC} $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; exit 1; }

echo ""
echo "=== Dark Centuries — Uninstall ==="
echo ""

# ── 1. Locate server install ─────────────────────────────────
SERVER_DIR=""
for candidate in "$HOME/games/wow-server-playerbots" "$HOME/wow-server-playerbots" "$HOME"/games/*/; do
    if [ -f "$candidate/docker-compose.yml" ] || [ -d "$candidate/env/dist/etc" ]; then
        SERVER_DIR="${candidate%/}"
        break
    fi
done
[ -n "$SERVER_DIR" ] || fail "No WotLK server install found."
ok "Server: $SERVER_DIR"

# ── 2. Remove Lua script (new + any legacy location) ─────────
removed=false
for lua in "$SERVER_DIR/env/dist/etc/modules/lua_scripts/dark_centuries.lua" \
           "/home/acore/azerothcore/lua_scripts/dark_centuries.lua"; do
    if [ -f "$lua" ]; then
        rm -f "$lua" && ok "Removed $lua" && removed=true
    fi
done
$removed || info "Lua script not found (already removed?)"

# ── 3. Remove SQL data ───────────────────────────────────────
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
if [ -n "$DB_CONTAINER" ]; then
    if ! docker ps --format '{{.Names}}' | grep -q "^$DB_CONTAINER$"; then
        info "Starting database container..."
        (cd "$SERVER_DIR" && docker compose up -d ac-database >/dev/null 2>&1) || true
    fi
    for i in $(seq 1 15); do
        docker exec "$DB_CONTAINER" mysqladmin ping -uroot -p"$DB_ROOT_PASSWORD" >/dev/null 2>&1 && break
        [ "$i" = 15 ] && fail "Database did not become ready."
        sleep 2
    done
    info "Removing SQL data..."
    docker exec -i "$DB_CONTAINER" mysql -uroot -p"$DB_ROOT_PASSWORD" acore_world 2>/dev/null <<'SQL'
DELETE FROM smart_scripts WHERE entryorguid IN (900001, 900002) AND source_type = 0;
DELETE FROM creature WHERE id1 IN (900001, 900002);
DELETE FROM creature_template WHERE entry IN (900001, 900002);
DROP TABLE IF EXISTS dc_zone_control;
SQL
    ok "SQL data removed"
else
    warn "Database container not found — SQL data not removed."
fi

# ── 4. Client addon (best effort) ────────────────────────────
_cache="$SERVER_DIR/.wow_client_dir"
if [ -f "$_cache" ]; then
    _saved=$(cat "$_cache")
    if [ -d "$_saved/Interface/AddOns/DarkCenturies" ]; then
        rm -rf "$_saved/Interface/AddOns/DarkCenturies" && ok "Client addon removed: $_saved"
    fi
fi
for pd in "$HOME/Games" "$HOME" /mnt/c/Games /mnt/d/Games /mnt/c /mnt/d; do
    for n in "World of Warcraft" "World of Warcraft 3.3.5a" "wow wotlk" "wotlk"              "ChromieCraft_3.3.5a" "wow 3.3.5a" "wow-client-3.3.5a" "wow-client"              "wow-wotlk-client" "WoW" "WoW-3.3.5a"; do
        p="$pd/$n"
        if [ -d "$p/Interface/AddOns/DarkCenturies" ]; then
            rm -rf "$p/Interface/AddOns/DarkCenturies" && ok "Client addon removed: $p"
        fi
    done
done

echo ""
ok "Dark Centuries uninstalled."
info "Restart the worldserver to apply:"
echo "         cd $SERVER_DIR && docker compose restart ac-worldserver"
echo ""
