#!/usr/bin/env bash
# DC intent bridge for mod-ollama-chat: grouped bots interpret natural-
# language MOVEMENT orders (come with me / wait here / dont follow) by
# LLM-classifying group members' messages into follow or stay, executing
# the real playerbot command, and acknowledging casually. Deliberately
# limited to follow/stay - the only target-free commands, so it can
# never produce command-error spam.
#
# Gated by conf: OllamaChat.EnableIntentBridge = 1
# Re-run after updating mod-ollama-chat, then rebuild the worldserver.
# Usage: SERVER_DIR=~/games/wow-server-playerbots ./ollama-intent-bridge.sh

set -e
SERVER_DIR="${SERVER_DIR:-$HOME/games/wow-server-playerbots}"
SRC="$SERVER_DIR/modules/mod-ollama-chat/src"
[ -d "$SRC" ] || { echo "[FAIL] $SRC not found"; exit 1; }

if grep -q "g_EnableIntentBridge" "$SRC/mod-ollama-chat_config.h"; then
    echo "[OK] already patched"; exit 0
fi

PAYLOAD_B64="eyJkZWNsX2giOiAiZXh0ZXJuIGJvb2wgZ19FbmFibGVJbnRlbnRCcmlkZ2U7IiwgImRlZl9jcHAiOiAiYm9vbCBnX0VuYWJsZUludGVudEJyaWRnZSA9IGZhbHNlOyIsICJsb2FkX2NwcCI6ICIgICAgZ19FbmFibGVJbnRlbnRCcmlkZ2UgPSBzQ29uZmlnTWdyLT5HZXRPcHRpb248Ym9vbD4oXCJPbGxhbWFDaGF0LkVuYWJsZUludGVudEJyaWRnZVwiLCBmYWxzZSk7IiwgInRocmVhZF9jYXAiOiAiICAgICAgICAvLyBEQyBpbnRlbnQgYnJpZGdlOiBncm91cGVkIHdoaXNwZXIvcGFydHkgbWVzc2FnZXMgZnJvbSBhIHJlYWxcbiAgICAgICAgLy8gcGxheWVyIG1heSBiZSBuYXR1cmFsLWxhbmd1YWdlIG9yZGVycy4gQ2xhc3NpZnkgdmlhIHRoZSBMTE0uXG4gICAgICAgIGJvb2wgdHJ5SW50ZW50ID0gZ19FbmFibGVJbnRlbnRCcmlkZ2UgJiYgIXNlbmRlcklzQm90ICYmXG4gICAgICAgICAgICAoc291cmNlTG9jYWwgPT0gU1JDX1dISVNQRVJfTE9DQUwgfHwgc291cmNlTG9jYWwgPT0gU1JDX1BBUlRZX0xPQ0FMKSAmJlxuICAgICAgICAgICAgYm90LT5HZXRHcm91cCgpICYmIGJvdC0+R2V0R3JvdXAoKSA9PSBwbGF5ZXItPkdldEdyb3VwKCk7XG5cbiAgICAgICAgc3RkOjp0aHJlYWQoW2JvdEd1aWQsIHNlbmRlckd1aWQsIHByb21wdCwgdHJ5SW50ZW50LCBzb3VyY2VMb2NhbCwiLCAid29ya2VyIjogIiAgICAgICAgICAgIHRyeSB7XG4gICAgICAgICAgICAgICAgc3RkOjpzdHJpbmcgd29ya1Byb21wdCA9IHByb21wdDtcbiAgICAgICAgICAgICAgICBpZiAodHJ5SW50ZW50KVxuICAgICAgICAgICAgICAgIHtcbiAgICAgICAgICAgICAgICAgICAgc3RkOjpzdHJpbmcgaW50ZW50UHJvbXB0ID1cbiAgICAgICAgICAgICAgICAgICAgICAgIFwiWW91IGNvbnRyb2wgYSBXb1cgY29tcGFuaW9uLiBSZXBseSB3aXRoIGV4YWN0bHkgT05FIHdvcmQ6IGZvbGxvdywgc3RheSwgb3Igbm9uZS4gXCJcbiAgICAgICAgICAgICAgICAgICAgICAgIFwiVXNlIGZvbGxvdyBPTkxZIGlmIHRoZSBwbGF5ZXIgY2xlYXJseSB3YW50cyB5b3UgdG8gY29tZSB3aXRoIHRoZW0gb3Igc3RpY2sgY2xvc2UgXCJcbiAgICAgICAgICAgICAgICAgICAgICAgIFwiKGNvbWUgd2l0aCBtZSwgbGV0cyBnbywgc3RpY2sgd2l0aCBtZSwga2VlcCB1cCkuIFwiXG4gICAgICAgICAgICAgICAgICAgICAgICBcIlVzZSBzdGF5IE9OTFkgaWYgdGhleSBjbGVhcmx5IHdhbnQgeW91IHRvIHdhaXQgb3Igc3RvcCBtb3ZpbmcgXCJcbiAgICAgICAgICAgICAgICAgICAgICAgIFwiKHdhaXQgaGVyZSwgaG9sZCBvbiwgc3RvcCwgZG9udCBmb2xsb3cgbWUpLiBcIlxuICAgICAgICAgICAgICAgICAgICAgICAgXCJGb3IgYW55dGhpbmcgZWxzZSAtIHF1ZXN0aW9ucywgZ3JlZXRpbmdzLCBjaGF0dGVyLCBhc2tpbmcgeW91IHRvIGRvIHNvbWV0aGluZyBcIlxuICAgICAgICAgICAgICAgICAgICAgICAgXCJvdGhlciB0aGFuIG1vdmluZyAtIHJlcGx5IG5vbmUuIFdoZW4gdW5zdXJlLCByZXBseSBub25lLiBcIlxuICAgICAgICAgICAgICAgICAgICAgICAgXCJSZXBseSB3aXRoIE9OTFkgdGhlIHdvcmQuIE1lc3NhZ2U6IFxcXCJcIiArIG1zZyArIFwiXFxcIlwiO1xuICAgICAgICAgICAgICAgICAgICBhdXRvIGludGVudEZ1dHVyZSA9IFN1Ym1pdFF1ZXJ5KGludGVudFByb21wdCk7XG4gICAgICAgICAgICAgICAgICAgIGlmIChpbnRlbnRGdXR1cmUudmFsaWQoKSlcbiAgICAgICAgICAgICAgICAgICAge1xuICAgICAgICAgICAgICAgICAgICAgICAgc3RkOjpzdHJpbmcgaW50ZW50ID0gaW50ZW50RnV0dXJlLmdldCgpO1xuICAgICAgICAgICAgICAgICAgICAgICAgc2l6ZV90IHNJZHggPSAwO1xuICAgICAgICAgICAgICAgICAgICAgICAgd2hpbGUgKHNJZHggPCBpbnRlbnQuc2l6ZSgpICYmIHN0ZDo6aXNzcGFjZSgodW5zaWduZWQgY2hhcilpbnRlbnRbc0lkeF0pKSArK3NJZHg7XG4gICAgICAgICAgICAgICAgICAgICAgICBzaXplX3QgZUlkeCA9IHNJZHg7XG4gICAgICAgICAgICAgICAgICAgICAgICB3aGlsZSAoZUlkeCA8IGludGVudC5zaXplKCkgJiYgIXN0ZDo6aXNzcGFjZSgodW5zaWduZWQgY2hhcilpbnRlbnRbZUlkeF0pXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgJiYgaW50ZW50W2VJZHhdICE9ICcuJyAmJiBpbnRlbnRbZUlkeF0gIT0gJywnICYmIGludGVudFtlSWR4XSAhPSAnIScpICsrZUlkeDtcbiAgICAgICAgICAgICAgICAgICAgICAgIGludGVudCA9IGludGVudC5zdWJzdHIoc0lkeCwgZUlkeCAtIHNJZHgpO1xuICAgICAgICAgICAgICAgICAgICAgICAgZm9yIChhdXRvJiBjaCA6IGludGVudCkgY2ggPSBzdGQ6OnRvbG93ZXIoKHVuc2lnbmVkIGNoYXIpY2gpO1xuXG4gICAgICAgICAgICAgICAgICAgICAgICBzdGF0aWMgY29uc3Qgc3RkOjpzZXQ8c3RkOjpzdHJpbmc+IHZhbGlkQ21kcyA9IHsgXCJmb2xsb3dcIiwgXCJzdGF5XCIgfTtcbiAgICAgICAgICAgICAgICAgICAgICAgIGlmICh2YWxpZENtZHMuY291bnQoaW50ZW50KSlcbiAgICAgICAgICAgICAgICAgICAgICAgIHtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICBQbGF5ZXIqIGNtZEJvdCA9IE9iamVjdEFjY2Vzc29yOjpGaW5kUGxheWVyKE9iamVjdEd1aWQoYm90R3VpZCkpO1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBsYXllciogY21kU2VuZGVyID0gT2JqZWN0QWNjZXNzb3I6OkZpbmRQbGF5ZXIoT2JqZWN0R3VpZChzZW5kZXJHdWlkKSk7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgaWYgKGNtZEJvdCAmJiBjbWRTZW5kZXIpXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQbGF5ZXJib3RBSSogY21kQUkgPSBQbGF5ZXJib3RzTWdyOjppbnN0YW5jZSgpLkdldFBsYXllcmJvdEFJKGNtZEJvdCk7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGlmIChjbWRBSSlcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAge1xuICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgY21kQUktPkhhbmRsZUNvbW1hbmQoQ0hBVF9NU0dfV0hJU1BFUiwgc1BsYXllcmJvdEFJQ29uZmlnLmNvbW1hbmRQcmVmaXggKyBpbnRlbnQsIGNtZFNlbmRlcik7XG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICB3b3JrUHJvbXB0ID0gcHJvbXB0ICtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBcIiAoWW91IGp1c3Qgc3RhcnRlZCBkb2luZyB3aGF0IHRoZXkgYXNrZWQuIFJlcGx5IHdpdGggT05MWSBhIFwiXG4gICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgXCIxLTQgd29yZCBjYXN1YWwgYWNrbm93bGVkZ21lbnQsIGxpa2U6IG9uIGl0IC8gb213IC8gayBnb3QgdSlcIjtcbiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAgICAgICAgIH1cbiAgICAgICAgICAgICAgICAgICAgfVxuICAgICAgICAgICAgICAgIH1cblxuICAgICAgICAgICAgICAgIC8vIFVzZSB0aGUgUXVlcnlNYW5hZ2VyIHRvIHN1Ym1pdCB0aGUgcXVlcnkuXG4gICAgICAgICAgICAgICAgYXV0byByZXNwb25zZUZ1dHVyZSA9IFN1Ym1pdFF1ZXJ5KHdvcmtQcm9tcHQpOyJ9"

python3 - "$SRC" "$PAYLOAD_B64" <<'PYEOF_INNER'
import sys, base64, json, re
src, b64 = sys.argv[1], sys.argv[2]
P = json.loads(base64.b64decode(b64).decode())

h = src + "/mod-ollama-chat_config.h"
s = open(h).read()
a = "extern bool g_DisableForCustomChannels;"
assert a in s, "config.h anchor"
open(h, "w").write(s.replace(a, a + chr(10) + P["decl_h"]))

c = src + "/mod-ollama-chat_config.cpp"
s = open(c).read()
m = re.search(r"^bool\s+g_DisableForCustomChannels\s*=[^
]*$", s, re.M)
assert m, "config.cpp def anchor"
s = s[:m.end()] + chr(10) + P["def_cpp"] + s[m.end():]
m = re.search(r"g_DisableForCustomChannels\s*=\s*sConfigMgr->GetOption<bool>\([^
]*\);", s)
assert m, "config.cpp load anchor"
s = s[:m.end()] + chr(10) + P["load_cpp"] + s[m.end():]
open(c, "w").write(s)

hd = src + "/mod-ollama-chat_handler.cpp"
s = open(hd).read()
nl = chr(10)
old_cap = ("        std::string prompt = GenerateBotPrompt(bot, msg, player);" + nl +
           "        uint64_t botGuid = bot->GetGUID().GetRawValue();" + nl +
           "        " + nl +
           "        std::thread([botGuid, senderGuid, prompt, sourceLocal,")
assert old_cap in s, "cap anchor"
new_cap = ("        std::string prompt = GenerateBotPrompt(bot, msg, player);" + nl +
           "        uint64_t botGuid = bot->GetGUID().GetRawValue();" + nl + nl +
           P["thread_cap"])
s = s.replace(old_cap, new_cap)

old_worker = ("            try {" + nl +
              "                // Use the QueryManager to submit the query." + nl +
              "                auto responseFuture = SubmitQuery(prompt);")
assert old_worker in s, "worker anchor"
s = s.replace(old_worker, P["worker"])

if "#include <set>" not in s:
    s = s.replace('#include "mod-ollama-chat_handler.h"',
                  '#include "mod-ollama-chat_handler.h"' + nl + '#include <set>' + nl + '#include <cctype>', 1)
if '#include "PlayerbotAIConfig.h"' not in s:
    s = s.replace('#include "PlayerbotAI.h"',
                  '#include "PlayerbotAI.h"' + nl + '#include "PlayerbotAIConfig.h"', 1)
open(hd, "w").write(s)
print("[OK] intent bridge patched (follow/stay) - rebuild the worldserver")
PYEOF_INNER
