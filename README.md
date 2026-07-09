# DC Launcher

Run your own **World of Warcraft: Wrath of the Lich King 3.3.5a** private server on Windows.  
One exe. No terminal. No subscription. No cloud. Fully offline. Populated with AI bots.

**[Download DC-Launcher.exe →](https://github.com/darkcenturies/dc-launcher/releases/latest)**

---

## What DC Launcher does differently

DC Launcher started as a fork of [Dad's MMO Lab](https://github.com/DadsMmoLab/dads-mmo-lab) by u/Kingspoken (AGPL-3.0), narrowed to WotLK 3.3.5a on Windows only. Here is everything that has been changed or fixed.

### Launcher — rebuilt from scratch

The original DML approach compiled `DML-Launcher.cs` from source at install time using `csc.exe` and ran it from `C:\DML\`. DC Launcher ships as a **pre-built exe** with a setup wizard built in.

| | DML | DC Launcher |
|--|-----|-------------|
| Distribution | Compile from source at install time | Pre-built exe, ships as a GitHub Release |
| Setup | Manual PowerShell steps | Guided 3-step wizard (base env → server → done) |
| Install location | `C:\DML\` (hardcoded) | `%ProgramFiles%\DC Launcher` (choosable in wizard) |
| Appears in Apps & Features | No | Yes — proper uninstall entry |
| Uninstall | Manual script | Settings → Apps → DC Launcher → Uninstall |
| Update | Re-run installer manually | Running a newer exe detects old install, offers hot-swap |
| Double-run conflict | Silent exit (nothing happens) | Shows update dialog instead |
| Already-running detection | Exits silently | Offers update even when tray is already running |
| UAC for Program Files | Not handled | Requests elevation automatically |
| Install path choice | Hardcoded | Folder picker in wizard, defaults to Program Files |
| Install detection | One hardcoded path | Checks Program Files, AppData, `C:\DCL`, `C:\DML` |
| CI/CD | None | GitHub Actions builds and publishes exe on every version tag |
| Manage/Backup when server off | Always enabled (misleading) | Grayed out when server is not running |
| Scope | Multi-game | WotLK 3.3.5a + Dark Centuries territory war |

### Installer fixes

**`Install-DML.ps1` parser failures** — the installer was broken on both PowerShell 5.1 and 7:
- Here-string content placed on the same line as `@'` — invalid in every PS version, caused 705 parse errors on PS 5.1 and ~30 on PS 7
- Missing UTF-8 BOM caused PS 5.1 to fall back to ANSI codepage, corrupting em-dashes in log messages and cascading into hundreds of spurious errors

Fixed: proper here-string formatting + UTF-8 BOM. Verified 0 parse errors on both PS 5.1 and PS 7.

### Tray launcher — v2.2 rewrite

Full rewrite of the tray launcher and server lifecycle:
- Persistent tray icon with right-click context menu (fixes Windows 11 left-click-only bug)
- Per-title Start / Restart / Stop with live status: Running (green) / Stopped (grey) / Loading (yellow dot animation — no menu resize jitter)
- Manages `wow-manage.sh` — interactive server console accessible from tray
- WSL RAM lifecycle: blocks Windows sleep while server is running, releases on stop
- Triggers `TriggerReleaseWsl` on exit so `VmmemWSL` actually frees memory
- Alt+Tab no longer shows a blank window entry for the tray app
- Backup per-title (not global)
- Recompile Launcher option in Extras menu
- Tray icon loaded from exe resources instead of a loose `dml.ico` file

### Further bug fixes

**Silent exception swallowing** — the original `Application.ThreadException` handler was an empty delegate, so all UI-thread crashes vanished silently. Fixed to show a MessageBox with the full stack trace when not running as the installed instance.

**Mutex causing "nothing happens"** — running a downloaded exe while the tray was already running hit the single-instance mutex and exited silently. Fixed: detects the non-installed case and shows an update/conflict dialog instead.

**Wizard showing when already installed** — `IsInstalledInstance()` only checked `%LOCALAPPDATA%\DC-Launcher\` but existing installs live at `C:\DML\`. Extended to check all known locations so the wizard is skipped when already installed.

**`Application.SetCompatibleTextRenderingDefault` called twice** — `WindowsFormsSynchronizationContext` in `Main()` creates a hidden control, incrementing the form count. Calling `SetCompatibleTextRenderingDefault` again inside `RunSetupWizard` threw. Removed the duplicate call.

**`.NET 4.0 csc.exe` syntax incompatibilities** — `?.` null-conditional operators and certain lambda forms aren't supported by the `csc.exe` that ships with Windows (.NET Framework 4.0, C# 4.0 syntax only). Replaced all `?.` with explicit null checks and all `=>` event handlers with `delegate` blocks.

**`Manage` terminal staying open** — when `wow-manage.sh` exited non-zero the terminal closed immediately. Fixed to keep it open so the user can read the error output.

**Manage/Backup via inline semicolons** — the original approach ran shell commands via inline `;` chaining which broke on paths with spaces. Rewrote to stage commands via a temp script file.

**Per-server backup paths** — backups were writing to a single global path regardless of which server was active.

**WoW WotLK icon** — replaced the generic `dml.ico` with the actual WoW WotLK icon embedded in the exe.

**Windows 11 mirrored networking** — added `networkingMode=mirrored` guidance in `.wslconfig` so LAN play works correctly on Windows 11 22H2+.

### Import Backup (new feature)

Right-click tray → Extras → Import Backup. Drop any `.sql.gz`, `.zip`, or `.sql` file from a previous backup and it restores directly into the live `ac-database` container — no terminal required.

---

## What you get

- AzerothCore WotLK 3.3.5a emulator running in Docker inside WSL2
- 600–800 Playerbots that level, run dungeons, and stock the Auction House
- Windows system tray app to start, stop, backup, and manage your server
- LAN support so other PCs on your network can connect
- **World of Warcraft: Dark Centuries** — a faction territory war across all of Azeroth (see below)
- Optional: AI-chatting bots via a local LLM ([mod-ollama-chat](https://github.com/DustinHendrickson/mod-ollama-chat) + Ollama) — whisper bots, make friends, they remember you

---

## World of Warcraft: Dark Centuries

A server-wide faction territory war, playable solo or with hundreds of playerbots.
Server side is an Eluna Lua script; client side is a bundled WoW addon.
Install/uninstall from the tray: **Extras → Dark Centuries**.

### The world

- **45 zones tracked** across Eastern Kingdoms and Kalimdor:
  - **15 Alliance home zones** (locked — can never be fought for): Elwynn Forest, Dun Morogh, Westfall, Redridge, Duskwood, Loch Modan, Wetlands, Stormwind, Ironforge, Teldrassil, Darkshore, Darnassus, Azuremyst, Bloodmyst, The Exodar
  - **11 Horde home zones** (locked): Durotar, Mulgore, The Barrens, Orgrimmar, Thunder Bluff, Tirisfal, Silverpine, Undercity, Eversong Woods, Ghostlands, Silvermoon
  - **19 contested warfronts** (capturable): Hillsbrad, Alterac, Arathi, Hinterlands, Western/Eastern Plaguelands, Badlands, Searing Gorge, Burning Steppes, Redridge front… plus Ashenvale, Stonetalon, Desolace, Thousand Needles, Feralas, Dustwallow, Azshara, Felwood
- **7 truly neutral zones** sit outside the war entirely (no tint, no capture, no bonuses): Moonglade, Stranglethorn Vale, Tanaris, Winterspring, Un'Goro Crater, Silithus, Deadwind Pass

### Capture mechanics

- **1 PvP kill = 1%** — each cross-faction player kill in a contested zone moves that zone's control meter one point toward the killer's faction (playerbot kills count: bots are players)
- A zone converts at **≤30% (Alliance)** or **≥70% (Horde)**; between those it's contested
- **No decay** — progress never depletes on its own, so solo campaigns stick; zones only move through kills or the war pulse
- **Autonomous war pulse** — every 3 minutes each contested zone has a 35% chance to shift 1–2% in a random direction, simulating off-screen battles, so front lines move even with nobody watching
- **Zone flips are server-wide news** — a colored announcement with the zone's total capture count
- After each kill the killer sees a colored capture bar with the zone's current split

### Rewards & feedback

- **+25% kill XP while in any zone your faction controls — including your own home zones**, so leveling in friendly territory is genuinely faster
- **Territory buff** — a visible aura (Essence of Wintergrasp) marks that you're in friendly-controlled territory; it appears/disappears live as you cross borders or zones flip
- The realm runs **PvP GameType** — everyone auto-flags in contested territory, and playerbots run an attack-on-sight PvP strategy with built-in self-preservation

### The territory map (client addon)

- **GTA:SA-style control overlay** on both continent maps: every zone tinted in its exact landmass shape — blue Alliance, red Horde, purple contested
- **Leaning contested zones pulse** between purple and the leading faction's color; pulse depth scales with the margin (52% barely shimmers, 69% throbs)
- **Hover any zone** for a colored status line: Alliance / Horde / Contested with the live % split / Neutral
- Color legend on the map; state survives `/reload` (SavedVariables) with a 20-second server resync as backup
- Slash commands: `/dc status` (faction totals + contested breakdown), `/dc map`, `/dc debug`

### Admin commands (GM level 3)

| Command | Effect |
|---|---|
| `.dc status` | Zone-by-zone control report |
| `.dc randomize` | Advance the war — zones captured/contested at random states |
| `.dc reset` | All contested zones back to even (50) |
| `.dc set <zoneId> <pct>` | Set a zone's meter directly (0 = Alliance … 100 = Horde) |
| `.dc war` | Fire one war pulse immediately |

### Persistence

- All zone state lives in the world DB (`dc_zone_control`) and survives restarts
- Clients sync on login, on zone change, on every change, plus a periodic full resync

---

## Requirements

- Windows 10 or 11 (64-bit)
- A legitimate WoW 3.3.5a client (not included)
- ~30 GB free disk space
- 8 GB RAM minimum (16 GB recommended)

---

## Install

1. Download **[DC-Launcher.exe](https://github.com/darkcenturies/dc-launcher/releases/latest)**
2. Run it — if SmartScreen appears, click **More info → Run anyway**
3. Follow the 3-step wizard:
   - **Step 1** — installs WSL2, Arch Linux, Docker (~10 min)
   - **Step 2** — installs AzerothCore WotLK server (~20 min, downloads ~10 GB)
   - **Done** — tray icon appears, right-click to start your server

---

## DC Launcher tray menu

Right-click the tray icon:

- **Start / Stop / Restart** your server
- **Manage** — open the server console (accounts, config, GM commands) *(server must be running)*
- **Backup** — back up your databases *(server must be running)*
- **LAN Play** — enable other PCs on your network to connect
- **Attach to Console** — live worldserver output
- **Extras**
  - Install New Title
  - Open DCL Shell
  - Run DCL Doctor
  - Check for Updates
  - Import Backup... — restore any `.sql.gz` backup into the live server
  - Restart active server/s
  - Stop WSL (release RAM)

---

## LAN Play

1. Right-click tray → your server name → **LAN Play → Enable**
2. Your LAN IP is shown in the dialog
3. Other players set their `realmlist.wtf` to that IP
4. Your own client stays on `127.0.0.1` — no change needed

---

## How it works

```
DC Launcher (Windows tray app)
    └── WSL2 (dml-arch — Arch Linux)
            └── Docker Engine
                    └── AzerothCore containers
                            ac-database   (MariaDB)
                            ac-authserver
                            ac-worldserver
```

---

## Files

| Path | Purpose |
|------|---------|
| `guides/DML-Windows/DML-Launcher.cs` | Launcher source (compiled by CI, AGPL-3.0) |
| `guides/DML-Windows/Install-DML.ps1` | Base environment installer (WSL2 + Docker) |
| `guides/wow-wotlk/Install-WoW-WotLK.ps1` | WotLK server installer |
| `guides/wow-wotlk/dml-start.sh` | Server start script (staged, waits for DB) |
| `guides/wow-wotlk/wow-manage.sh` | Interactive server manager |
| `dark-centuries/` | Dark Centuries territory war (server Lua + client addon + SQL) |
| `.github/workflows/release.yml` | CI: builds and releases exe on version tag |

---

## Legal

This project does not include or distribute any Blizzard game files.  
You must supply your own legally obtained WoW 3.3.5a client.  
For personal offline use only — not for running public servers.

- Server emulator: [AzerothCore](https://github.com/azerothcore/azerothcore-wotlk) (AGPL-3.0)
- Not affiliated with or endorsed by Blizzard Entertainment

---

## License

[AGPL-3.0](./LICENSE-AGPL)

Based on [Dad's MMO Lab](https://github.com/DadsMmoLab/dads-mmo-lab) by u/Kingspoken — narrowed to WotLK on Windows with a self-installing launcher. Changes tracked in git history.
