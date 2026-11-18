# LFG+

The in-game half of [lfg.plus](https://lfg.plus): see who other players endorsed, right in your tooltip, and endorse
the people you enjoyed grouping with after a run.

## Overview

Hover over a player and LFG+ adds a few lines under their name:

```
LFG+ Endorsements:
  Fun          34
  Skilled     100
  Helpful      23
  Leader       55
```

Each tag has its icon, and its number is how many times players endorsed them for it. Someone nobody has endorsed yet
reads `LFG+ No endorsements yet`. Players you endorsed yourself also show `You endorsed them`, with the tag you picked.

The same lines show on applicants to your group and on listings in the group finder, so you can see who you're about
to run with.

## Endorsing

After a dungeon, raid or scenario, once you're out of combat, LFG+ shows a short list of your group. For anyone you'd
run with again, click what they did best:

| Tag | Meaning |
|---|---|
| **Fun** | Good company. They made the run a good time. |
| **Skilled** | Knew their role and played it really well. |
| **Helpful** | Went out of their way for someone: explained a fight, summoned, crafted, carried. |
| **Leader** | Kept the group organised: set the pace, marked, made the calls. |

You can also endorse anyone nearby: right-click their portrait or party or raid frame and choose **Endorse**, or
target them and type `/endorse fun` (or `skilled`, `helpful`, `leader`).

The same right-click menu has **Copy LFG+ URL**: it shows the player's profile address on lfg.plus, selected, ready
for Ctrl+C.

A few things to know:

- **Best when both players have LFG+.** Their addon answers yours, which proves you grouped. Without an answer the
  endorsement still counts. By default LFG+ answers on its own; you can have it ask you first, separately for your
  group, guild, friends and everyone else.
- **Once per player, ever.** Each player can be endorsed once. You can give up to 20 endorsements a day.
- **Quiet endorsements.** Shift-click a tag, or add `quiet` to the command. It looks exactly like an endorsement to
  the other player, but doesn't count on the site. It's for when you'd rather not.
- **A thank-you whisper, if you like.** Turn it on with `/lfgplus thanks` or in the settings, and whoever you
  endorse gets a short, friendly whisper for what they did, like
  `[LFG.plus] Thanks for playing your role so well, you made it look easy. I endorsed you as Skilled.` It's off until
  you turn it on.
- **`/thank` endorses too.** Target a player you haven't endorsed yet and `/thank` them, and LFG+ endorses them as
  Helpful. Turn it off with `/lfgplus emote` or in the settings.
- **Nothing is sent in combat.** Messages wait until combat or the boss encounter ends.

## Getting started

1. **Install LFG+** from [CurseForge](https://www.curseforge.com/), [Wago](https://addons.wago.io/) or
   [lfg.plus/addon](https://lfg.plus/addon).
2. **Install the daily data.** Tooltips read from a second add-on, **LFG+ Data**, rebuilt every night for each game
   version and region. CurseForge and Wago keep it up to date; if you install by hand from
   [lfg.plus/addon](https://lfg.plus/addon), put its folder (like `LFGPlus_Data_Forever_US`) next to `LFGPlus` in
   `Interface/AddOns` and download it again every few days.
3. **Link your account.** Log in on [lfg.plus](https://lfg.plus) with Battle.net, open your account page and copy your
   setup code. In the game, type `/lfgplus setup` and paste it. The code stays on your computer and never appears in
   chat.
4. **Upload your endorsements.** Type `/lfgplus upload`, copy everything in the box, paste it on
   [lfg.plus/upload](https://lfg.plus/upload), then press **I uploaded these**. That's what makes them count on the site.

LFG+ loads in Retail, Classic Era, Mists of Pandaria Classic and WoW Forever.

## Commands

| Command | What it does |
|---|---|
| `/lfgplus` | Open the LFG+ window (also the minimap button; right-click it for settings) |
| `/lfgplus help` | Status and the command list |
| `/lfgplus settings`, `/lfgplus minimap` | Open the Settings tab; show or hide the minimap button |
| `/lfgplus setup` | Paste the setup code from lfg.plus (a dialog, so it never sits in chat history) |
| `/endorse fun\|skilled\|helpful\|leader [quiet]` | Endorse your target (a tag is required). Or right-click a player's portrait or party/raid frame and choose **Endorse** |
| `/lfgplus group` | Open the endorse window for your current group (without finishing a run) |
| `/lfgplus upload` | The upload box: copy every record, paste on lfg.plus/upload (in parts of 500 when there are more), then press **I uploaded these** |
| `/lfgplus records` | How many records are waiting to be uploaded |
| `/lfgplus prompt`, `/lfgplus sound` | Turn the post-run prompt or the toast sound on/off |
| `/lfgplus thanks` | Turn the thank-you whisper to players you endorse on/off |
| `/lfgplus emote` | Turn endorsing as Helpful on `/thank` on/off |
| `/lfgplus ack group\|guild\|friends\|others auto\|ask` | Answer endorsement requests automatically, or ask first |
| `/lfgplus unlink` | Remove the account link |
| `/lfgplus reset` | Delete everything LFG+ Addon keeps on this account (setup code, settings, records), after asking; the log stays |

## Configuring

Open the LFG+ window with `/lfgplus` or the minimap button. It has three tabs: **Overview**, **Endorsements** (the ones
you gave) and **Settings**. Turning on the detailed log (in Settings, or `/lfgplus debug`) adds a fourth, **Log**, for
bug reports. The settings are also under Options → AddOns → LFG+.

## Privacy

Endorsed characters are public on lfg.plus until their owner hides them. Log in on lfg.plus to hide any of your
characters; the addon reads the next day's data and stops showing them too.

## Support

Questions, bugs, or a story about a great group? Write to [support@lfg.plus](mailto:support@lfg.plus). Short answers
are in the [FAQ](https://lfg.plus/faq).

## Development

LFG+ ships as two add-ons: **`LFGPlus`**, the code, and **`LFGPlus_Data_<Version>_<Region>`**, a load-on-demand
data add-on built by lfg.plus every night. `LFGPlus_Data_Forever_US/` here is a development copy made from test
characters: never edit it by hand.

This repository is checked out as the `addon/` submodule of the lfg.plus repository.

### Test vectors

`test/test-vectors/` holds golden files for every format LFG+ shares with lfg.plus: HMAC-SHA256 (RFC 4231), key
derivation, setup codes, endorsement records, character keys and the packed data add-on. The site's code and these
specs are both tested against them, so any other implementation can check itself the same way. Each file says what
it holds in its `description`.

### Layout

```
LFGPlus/            the addon as players install it (load order is the TOC's)
  LFGPlus.toc       load order, SavedVariables LFGPlusDB (settings, records) and LFGPlusLog (the log)
  Core.lua          namespace, saved-variable defaults, game-version detection, ADDON_LOADED
  Log.lua           persistent ring-buffer log, error capture (Log.Guard / Log.Wrap)
  Crypto.lua        SHA-256, HMAC-SHA256, addon key derivation (pure)
  SetupCode.lua     setup code v1 parsing (pure)
  Settings.lua      account link, toggles, ack settings, /lfgplus status lines
  Identity.lua      who a character is, per game version (Forever: "First Surname", no realm)
  Diagnostics.lua   client facts at login and per group member
  Record.lua        endorsement record v1 codec and MACs (pure)
  Comm.lua          addon-message queue: whispers, and finished records to the group channel; held in combat and encounters, throttled
  Endorse.lua       the handshake: request, ack, record; counter, daily cap, quiet endorsements; carrying records heard in the group
  Runs.lua          notices when a dungeon or raid ends, for the post-run prompt
  Format.lua        every string the tooltip shows (pure)
  Data.lua          loads the data add-on for this game version and region; LFGPlus_RegisterData, lookups
  Tooltip.lua       the LFG+ tooltip line
  UI.lua            post-run prompt, endorse popup, endorsed toast, "ask first" popup, upload box
  Window.lua        the LFG+ window (Overview, Endorsements, Settings, Log) and the Options → AddOns page
  UnitMenu.lua      "Endorse" in a player's right-click menu (Menu API), opening the endorse popup
  Minimap.lua       the minimap button and broker launcher (LibDataBroker + LibDBIcon), Retail's addon compartment
  Slash.lua         /lfgplus, /endorse, and endorsing on /thank
  Events.lua        event wiring, every handler guarded
  Libs/             embedded third-party libraries, under their own licences (Libs/README.md)
  Media/Icon.tga    the minimap and addon-list icon, drawn by tools/make-icon.mjs
  Media/Tag-*.tga   the four tag icons on the prompt's buttons, generated from the website's drawings
test/               busted specs (run outside the game, in real Lua 5.1)
tools/              make-icon.mjs: redraws Media/Icon.tga (Node, no dependencies); package.sh: builds the release zip
.github/workflows/  release.yml: specs, then a release, on every push to main
```

### Tests

Pure code (formatting, encoders, crypto) is tested in **real Lua 5.1** with [busted](https://lunarmodules.github.io/busted/),
because WoW runs Lua 5.1 and a newer Lua would hide incompatibilities.

```bash
./busted.sh       # or any busted arguments: ./busted.sh test/crypto_spec.lua
```

`busted.sh` uses the first of: a repo-local install in `.lua/`, `busted` on your `PATH` (when it runs Lua 5.1), or
Docker, which builds the small image in `test/docker/` once (Debian, Lua 5.1, pinned busted, dkjson and luabitop) and
reuses it.

`./coverage.sh` runs the same specs with luacov (lines) and `test/helpers/coverage.lua` (branches: every `then`,
`else` and implicit `else`), then fails unless every line and branch of `LFGPlus/` (not `Libs/`) ran.
Coverage-ignore comments aren't allowed: test the path or remove it.

Setting up Lua 5.1 natively without admin rights (needs a C compiler):

```bash
pip install hererocks
hererocks .lua -l 5.1 -r latest
source .lua/bin/activate      # Windows: .lua\bin\activate.bat
luarocks install busted && luarocks install dkjson && luarocks install luabitop
```

If lua.org is unreachable or readline headers are missing, build Lua 5.1 from
GitHub's tag instead: `hererocks .lua -l @v5.1 -r latest --no-readline`.

### Releases

Every push to `main` runs the specs with full line and branch coverage (`.github/workflows/release.yml`). When they
pass, `tools/package.sh` builds `LFGPlus-<version>.zip`, and it's published on the
[Releases](https://github.com/JollyCooperationLLC/lfgplus-addon/releases) page. The version is the UTC time of the
build, `year.month.day.hourminutesecond` (for example `2026.11.18.010203`), written into the zip's `LFGPlus.toc`;
the TOC in the repository keeps a placeholder. To build the same zip locally:

```bash
tools/package.sh 2026.11.18.010203   # writes dist/LFGPlus-2026.11.18.010203.zip
```

### Development and testing methodology

- Files that touch the WoW API stay thin. Logic goes in pure functions that take values, so specs can call them.
- Never do anything in combat that the client restricts. Queue addon messages until combat or the encounter ends.
- Every byte format (records, the export) is checked against `test/test-vectors/`.

## License

All rights reserved - Jolly Cooperation LLC. The embedded libraries in `LFGPlus/Libs/` keep their own terms.
