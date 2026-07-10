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
# Channel replies: custom channels (World) have ID 0 and fell through
# to /say delivery - route by name and source instead
old = "if (channelId != 0 && !channelName.empty())"
new = "if (!channelName.empty() && sourceLocal == SRC_GENERAL_LOCAL)"
if old in s:
    s = s.replace(old, new)
    open(hd, "w").write(s)

print("[OK] intent bridge patched (follow/stay) - rebuild the worldserver")
PYEOF_INNER

# World ambient chatter: distant bots keep the World channel alive;
# nearby bots gain World as an extra chatter destination
export SERVER_DIR
python3 - <<'PYEOF_WORLD'
import os
p = os.environ['SERVER_DIR'] + '/modules/mod-ollama-chat/src/mod-ollama-chat_random.cpp'
s = open(p).read()
if 'DC: distant bots occasionally chat' in s:
    print('[OK] world chatter already patched')
    raise SystemExit(0)

# A. Loop gate: distant bots get a small chance to chat into World
old = """        // Guild bots with real guild members online can bypass proximity requirement
        bool allowWithoutProximity = guild && hasRealPlayerInGuild;
        if (!allowWithoutProximity && !nearRealPlayer)
            continue;"""
new = """        // Guild bots with real guild members online can bypass proximity requirement
        bool allowWithoutProximity = guild && hasRealPlayerInGuild;
        // DC: distant bots occasionally chat into the World channel so the
        // global channel stays alive even with no player nearby (small
        // chance keeps volume sane across hundreds of bots)
        bool worldOnly = false;
        if (!allowWithoutProximity && !nearRealPlayer)
        {
            if (!realPlayers.empty() && urand(0, 99) < 3)
                worldOnly = true;
            else
                continue;
        }"""
assert old in s, "gate"
s = s.replace(old, new)

# B. Thread capture
old = "std::thread([botGuid, prompt, isGuildComment]() {"
new = "std::thread([botGuid, prompt, isGuildComment, worldOnly]() {"
assert old in s, "capture"
s = s.replace(old, new)

# C. Pre-validation: World lane is always a valid destination
old = "            bool hasValidDestination = false;"
new = "            bool hasValidDestination = worldOnly;"
assert old in s, "prevalid"
s = s.replace(old, new)

# D. Channel options: add World (exclusive for the distant lane)
old = """                        // If no channels are available, skip random chatter
                        if (channels.empty())"""
new = """                        // DC: World channel as a destination — exclusive for the
                        // distant-bot lane, an extra option for nearby bots
                        if (worldOnly)
                            channels.clear();
                        {
                            ChannelMgr* wMgr = ChannelMgr::forTeam(botPtr->GetTeamId());
                            Channel* wCh = wMgr ? wMgr->GetChannel("World", botPtr) : nullptr;
                            if (wCh && botPtr->IsInChannel(wCh))
                                channels.push_back("World");
                        }

                        // If no channels are available, skip random chatter
                        if (channels.empty())"""
assert old in s, "channels"
s = s.replace(old, new)

# E. Send branch for World
old = "                        } else if (selectedChannel == \"General\") {"
new = """                        } else if (selectedChannel == "World") {
                            ChannelMgr* cMgr = ChannelMgr::forTeam(botPtr->GetTeamId());
                            Channel* worldChannel = cMgr ? cMgr->GetChannel("World", botPtr) : nullptr;
                            if (worldChannel && botPtr->IsInChannel(worldChannel))
                            {
                                if (g_DebugEnabled)
                                    LOG_INFO("server.loading", "[Ollama Chat] Bot {} Random Chatter World: {}", botPtr->GetName(), response);
                                worldChannel->Say(botPtr->GetGUID(), response, LANG_UNIVERSAL);
                                ProcessBotChatMessage(botPtr, response, SRC_GENERAL_LOCAL, worldChannel);
                            }
                        } else if (selectedChannel == "General") {"""
assert old in s, "send"
s = s.replace(old, new)

open(p, 'w').write(s)
print("world chatter patched")

PYEOF_WORLD

# Priority queue + presence gating: interactive replies (whisper > raid >
# party > say/yell > guild > World > general) always outrank ambient
# chatter, ambient work is capped to half the Ollama slots so a player
# speaking in party AND world gets both answers while idle chatter
# continues, and ambient World chatter only runs while a real player is
# actually in the World channel.
python3 - <<'PYEOF_PRIORITY'
#!/usr/bin/env python3
# DC: priority-aware QueryManager + per-channel presence gating for mod-ollama-chat.
# Idempotent: each step checks a marker before applying.
import sys

import os
SRC = os.environ['SERVER_DIR'] + '/modules/mod-ollama-chat/src/'

def load(name):
    with open(SRC + name, "r", encoding="utf-8") as f:
        return f.read()

def save(name, text):
    with open(SRC + name, "w", encoding="utf-8") as f:
        f.write(text)

changed = []

# ---------------------------------------------------------------- querymanager.h
name = "mod-ollama-chat_querymanager.h"
t = load(name)
if "QUERY_PRIO_AMBIENT" not in t:
    save(name, """#ifndef MOD_OLLAMA_CHAT_QUERYMANAGER_H
#define MOD_OLLAMA_CHAT_QUERYMANAGER_H

#include <string>
#include <future>
#include <mutex>
#include <vector>
#include <thread>
#include <cstdint>

std::string QueryOllamaAPI(const std::string& prompt);

// DC: query priorities - lower value is answered first. Interactive replies
// (whisper/raid/party/say) always jump ahead of ambient background chatter,
// and ambient work may never occupy every Ollama slot, so a real player who
// speaks in party AND world gets both answers while idle chatter continues.
enum QueryPriority
{
    QUERY_PRIO_WHISPER  = 0,
    QUERY_PRIO_RAID     = 1,
    QUERY_PRIO_PARTY    = 2,
    QUERY_PRIO_SAY      = 3,   // say / yell proximity chat
    QUERY_PRIO_GUILD    = 4,
    QUERY_PRIO_WORLD    = 5,   // World custom channel replies
    QUERY_PRIO_GENERAL  = 6,   // General / other channel replies
    QUERY_PRIO_AMBIENT  = 9    // random chatter, bot-to-bot, sentiment
};

class QueryManager {
public:
    QueryManager();
    void setMaxConcurrentQueries(int maxQueries);
    std::future<std::string> submitQuery(const std::string& prompt, int priority = QUERY_PRIO_AMBIENT);

private:
    struct QueryTask {
        std::string prompt;
        std::promise<std::string> promise;
        int priority;
        uint64_t seq;   // FIFO order within the same priority
    };

    void processQuery(std::string prompt, std::promise<std::string> promise, bool ambient);
    void startNextLocked();   // caller must hold mutex_
    int ambientCapLocked() const;

    int maxConcurrentQueries; // 0 means no limit
    int currentQueries;
    int currentAmbient;       // ambient queries currently in flight
    uint64_t nextSeq;
    std::mutex mutex_;
    std::vector<QueryTask> taskQueue;
};

#endif // MOD_OLLAMA_CHAT_QUERYMANAGER_H
""")
    changed.append(name)

# ---------------------------------------------------------------- querymanager.cpp
name = "mod-ollama-chat_querymanager.cpp"
t = load(name)
if "startNextLocked" not in t:
    save(name, """#include "mod-ollama-chat_querymanager.h"
#include "mod-ollama-chat_config.h"  // For g_MaxConcurrentQueries
#include <algorithm>
#include <climits>
#include <thread>

// Constructor: initialize with the configuration value.
QueryManager::QueryManager()
    : maxConcurrentQueries(g_MaxConcurrentQueries), currentQueries(0), currentAmbient(0), nextSeq(0)
{
}

// Set maximum concurrent queries (0 means no limit).
void QueryManager::setMaxConcurrentQueries(int maxQueries) {
    std::lock_guard<std::mutex> lock(mutex_);
    maxConcurrentQueries = maxQueries;
}

// Ambient work may take at most half the slots so interactive replies to a
// real player always have room to run immediately.
int QueryManager::ambientCapLocked() const {
    if (maxConcurrentQueries == 0)
        return INT_MAX;
    return std::max(1, maxConcurrentQueries / 2);
}

// Submit a query and return a future for the result.
std::future<std::string> QueryManager::submitQuery(const std::string& prompt, int priority) {
    std::promise<std::string> promise;
    std::future<std::string> future = promise.get_future();

    bool ambient = priority >= QUERY_PRIO_AMBIENT;
    bool shouldRunNow = false;

    {
        std::lock_guard<std::mutex> lock(mutex_);

        // Shed excess ambient work instead of queueing it forever - callers
        // treat an empty response as "skip this chatter line".
        if (ambient) {
            int pendingAmbient = 0;
            for (auto const& task : taskQueue)
                if (task.priority >= QUERY_PRIO_AMBIENT)
                    ++pendingAmbient;
            if (pendingAmbient >= 10) {
                promise.set_value("");
                return future;
            }
        }

        bool slotFree = (maxConcurrentQueries == 0 || currentQueries < maxConcurrentQueries);
        if (slotFree && (!ambient || currentAmbient < ambientCapLocked())) {
            ++currentQueries;
            if (ambient) ++currentAmbient;
            shouldRunNow = true;
        } else {
            QueryTask task;
            task.prompt = prompt;
            task.promise = std::move(promise);
            task.priority = priority;
            task.seq = nextSeq++;
            taskQueue.push_back(std::move(task));
        }
    }

    if (shouldRunNow) {
        std::thread(&QueryManager::processQuery, this, prompt, std::move(promise), ambient).detach();
    }

    return future;
}

// Process the query by calling the API and then handling any queued tasks.
void QueryManager::processQuery(std::string prompt, std::promise<std::string> promise, bool ambient) {
    std::string result = QueryOllamaAPI(prompt);
    promise.set_value(result);

    std::lock_guard<std::mutex> lock(mutex_);
    --currentQueries;
    if (ambient) --currentAmbient;
    startNextLocked();
}

// Start the most urgent eligible queued task (lowest priority value wins,
// FIFO within the same priority; ambient respects its slot cap).
void QueryManager::startNextLocked() {
    if (taskQueue.empty())
        return;
    if (maxConcurrentQueries != 0 && currentQueries >= maxConcurrentQueries)
        return;

    size_t best = taskQueue.size();
    for (size_t i = 0; i < taskQueue.size(); ++i) {
        bool amb = taskQueue[i].priority >= QUERY_PRIO_AMBIENT;
        if (amb && currentAmbient >= ambientCapLocked())
            continue;
        if (best == taskQueue.size()
            || taskQueue[i].priority < taskQueue[best].priority
            || (taskQueue[i].priority == taskQueue[best].priority && taskQueue[i].seq < taskQueue[best].seq))
            best = i;
    }
    if (best == taskQueue.size())
        return;

    QueryTask task = std::move(taskQueue[best]);
    taskQueue.erase(taskQueue.begin() + best);
    bool amb = task.priority >= QUERY_PRIO_AMBIENT;
    ++currentQueries;
    if (amb) ++currentAmbient;
    std::thread(&QueryManager::processQuery, this, task.prompt, std::move(task.promise), amb).detach();
}
""")
    changed.append(name)

# ---------------------------------------------------------------- api.h / api.cpp
name = "mod-ollama-chat_api.h"
t = load(name)
old = "std::future<std::string> SubmitQuery(const std::string& prompt);"
new = "std::future<std::string> SubmitQuery(const std::string& prompt, int priority = QUERY_PRIO_AMBIENT);"
if old in t:
    save(name, t.replace(old, new))
    changed.append(name)
else:
    assert new in t, "api.h: SubmitQuery declaration not found"

name = "mod-ollama-chat_api.cpp"
t = load(name)
old = """std::future<std::string> SubmitQuery(const std::string& prompt)
{
    return g_queryManager.submitQuery(prompt);
}"""
new = """std::future<std::string> SubmitQuery(const std::string& prompt, int priority)
{
    return g_queryManager.submitQuery(prompt, priority);
}"""
if old in t:
    save(name, t.replace(old, new))
    changed.append(name)
else:
    assert "submitQuery(prompt, priority)" in t, "api.cpp: SubmitQuery definition not found"

# ---------------------------------------------------------------- handler.cpp
name = "mod-ollama-chat_handler.cpp"
t = load(name)
if "queryPriority" not in t:
    anchor = "bot->GetGroup() && bot->GetGroup() == player->GetGroup();\n"
    assert anchor in t, "handler.cpp: tryIntent anchor not found"
    insert = anchor + """
        // DC: interactive replies outrank ambient chatter so a real player who
        // speaks in party AND world gets both answers while idle chatter runs.
        // Order: whisper > raid > party > say/yell > guild > World > general.
        int queryPriority;
        switch (sourceLocal)
        {
            case SRC_WHISPER_LOCAL: queryPriority = QUERY_PRIO_WHISPER; break;
            case SRC_RAID_LOCAL:    queryPriority = QUERY_PRIO_RAID;    break;
            case SRC_PARTY_LOCAL:   queryPriority = QUERY_PRIO_PARTY;   break;
            case SRC_SAY_LOCAL:
            case SRC_YELL_LOCAL:    queryPriority = QUERY_PRIO_SAY;     break;
            case SRC_GUILD_LOCAL:
            case SRC_OFFICER_LOCAL: queryPriority = QUERY_PRIO_GUILD;   break;
            case SRC_GENERAL_LOCAL:
                queryPriority = (channel && channel->GetName() == "World")
                    ? QUERY_PRIO_WORLD : QUERY_PRIO_GENERAL;
                break;
            default:                queryPriority = QUERY_PRIO_GENERAL; break;
        }
        // Bot-to-bot conversations are background flavor - never let them
        // crowd out a reply to a real player.
        if (senderIsBot)
            queryPriority = QUERY_PRIO_AMBIENT;
"""
    t = t.replace(anchor, insert, 1)

    cap_old = "std::thread([botGuid, senderGuid, prompt, tryIntent, sourceLocal,"
    cap_new = "std::thread([botGuid, senderGuid, prompt, tryIntent, queryPriority, sourceLocal,"
    assert cap_old in t, "handler.cpp: thread capture anchor not found"
    t = t.replace(cap_old, cap_new, 1)

    assert "SubmitQuery(intentPrompt)" in t, "handler.cpp: intent SubmitQuery not found"
    t = t.replace("SubmitQuery(intentPrompt)", "SubmitQuery(intentPrompt, queryPriority)", 1)
    assert "SubmitQuery(workPrompt)" in t, "handler.cpp: work SubmitQuery not found"
    t = t.replace("SubmitQuery(workPrompt)", "SubmitQuery(workPrompt, queryPriority)", 1)

    save(name, t)
    changed.append(name)

# ---------------------------------------------------------------- random.cpp
name = "mod-ollama-chat_random.cpp"
t = load(name)
if "realPlayerInWorldChannel" not in t:
    anchor = """        if (!PlayerbotsMgr::instance().GetPlayerbotAI(player))
            realPlayers.push_back(player);
    }
"""
    assert anchor in t, "random.cpp: realPlayers anchor not found"
    insert = anchor + """
    // DC: ambient World chatter only runs while a real player is actually in
    // the World channel - when they leave, the chatter (and its LLM cost)
    // stops; when they rejoin, it resumes.
    bool realPlayerInWorldChannel = false;
    for (Player* rp : realPlayers)
    {
        ChannelMgr* rpMgr = ChannelMgr::forTeam(rp->GetTeamId());
        Channel* rpCh = rpMgr ? rpMgr->GetChannel("World", rp, false) : nullptr;
        if (rpCh && rp->IsInChannel(rpCh))
        {
            realPlayerInWorldChannel = true;
            break;
        }
    }
"""
    t = t.replace(anchor, insert, 1)

    gate_old = "if (!realPlayers.empty() && urand(0, 99) < 3)"
    gate_new = "if (realPlayerInWorldChannel && urand(0, 99) < 3)"
    assert gate_old in t, "random.cpp: worldOnly gate not found"
    t = t.replace(gate_old, gate_new, 1)

    cap_old = "std::thread([botGuid, prompt, isGuildComment, worldOnly]()"
    cap_new = "std::thread([botGuid, prompt, isGuildComment, worldOnly, realPlayerInWorldChannel]()"
    assert cap_old in t, "random.cpp: chatter thread capture not found"
    t = t.replace(cap_old, cap_new, 1)

    q_old = """                    // Generate response from LLM
                    std::string response = QueryOllamaAPI(prompt);"""
    q_new = """                    // Generate response from LLM at the lowest priority -
                    // ambient chatter must never crowd out replies to players
                    auto responseFuture = SubmitQuery(prompt, QUERY_PRIO_AMBIENT);
                    if (!responseFuture.valid()) return;
                    std::string response = responseFuture.get();"""
    assert q_old in t, "random.cpp: QueryOllamaAPI call not found"
    t = t.replace(q_old, q_new, 1)

    dest_old = "if (wCh && botPtr->IsInChannel(wCh))"
    dest_new = "if (realPlayerInWorldChannel && wCh && botPtr->IsInChannel(wCh))"
    assert dest_old in t, "random.cpp: World destination check not found"
    t = t.replace(dest_old, dest_new, 1)

    save(name, t)
    changed.append(name)

# ---------------------------------------------------------------- sentiment.cpp
name = "mod-ollama-chat_sentiment.cpp"
t = load(name)
old = """    // Query the LLM for sentiment analysis
    std::string response = QueryOllamaAPI(prompt);"""
new = """    // Query the LLM for sentiment analysis (lowest priority - this is
    // bookkeeping and must never delay a reply to a real player)
    std::string response = SubmitQuery(prompt, QUERY_PRIO_AMBIENT).get();"""
if old in t:
    save(name, t.replace(old, new))
    changed.append(name)
else:
    assert "SubmitQuery(prompt, QUERY_PRIO_AMBIENT)" in t, "sentiment.cpp: call not found"

if changed:
    print("PATCHED: " + ", ".join(changed))
else:
    print("ALREADY APPLIED - nothing to do")
PYEOF_PRIORITY
