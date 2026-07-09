#!/usr/bin/env bash
# Removes the <Away> tag from playerbots in minimal-activity mode.
# The AFK flag was only a cosmetic marker — the resource saving is the
# reduced AI tick, which this patch does not touch. The flag-clearing
# branch is kept so stale AFK flags clean themselves up.
#
# Re-run after updating mod-playerbots (git pull reverts the patch),
# then rebuild the worldserver.
#
# Usage: SERVER_DIR=~/games/wow-server-playerbots ./playerbots-no-afk-tag.sh

set -e
SERVER_DIR="${SERVER_DIR:-$HOME/games/wow-server-playerbots}"
SRC="$SERVER_DIR/modules/mod-playerbots/src/Bot/PlayerbotAI.cpp"

[ -f "$SRC" ] || { echo "[FAIL] $SRC not found"; exit 1; }

if grep -q "DC patch: minimal-activity" "$SRC"; then
    echo "[OK] already patched"
    exit 0
fi

python3 - "$SRC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''        if (!bot->isAFK() && !bot->InBattleground() && !HasRealPlayerMaster())
            bot->ToggleAFK();'''
new = '''        // DC patch: minimal-activity mode no longer flags bots <Away> —
        // the resource saving is the reduced AI tick below, the AFK flag
        // was only a cosmetic marker that made bots look unavailable.
        // (The un-AFK branch below is kept so stale flags clear themselves.)'''
assert old in s, "anchor not found — mod-playerbots source changed, update this patch"
open(p, 'w').write(s.replace(old, new, 1))
print("[OK] patched — rebuild the worldserver to apply")
PYEOF
