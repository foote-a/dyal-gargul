# Dyal Gargul — Rolling SR Edition

> [!IMPORTANT]
> **Fork Notice & Upstream Attribution:**
> This repository is a specialized fork of the official [Gargul](https://github.com/papa-smurf/Gargul) World of Warcraft addon created by **Zhorax** ([CurseForge](https://www.curseforge.com/wow/addons/gargul) | [Wago](https://addons.wago.io/addons/gargul) | [Patreon](https://www.patreon.com/gargul)).
>
> This fork exists specifically to implement our guild's custom **Two-Phase Rolling Soft Reserve ("Rolling SR")** loot system with weekly bonus roll accumulation, Mains vs. Alts eligibility rules, and Google Sheets Apps Script integration.
>
> **For all other use cases** (standard GDKP, traditional SoftRes, That's My Bis / TMB, ClassicPR, RRobin, standard +1 systems, and general Master Loot management), **we strongly recommend using the official upstream Gargul addon:**
> - **Official GitHub:** [https://github.com/papa-smurf/Gargul](https://github.com/papa-smurf/Gargul)
> - **Official CurseForge:** [https://www.curseforge.com/wow/addons/gargul](https://www.curseforge.com/wow/addons/gargul)
> - **Official Wago:** [https://addons.wago.io/addons/gargul](https://addons.wago.io/addons/gargul)
>
> Please only use this fork if you specifically need the Rolling SR loot rules documented below.

---

## Table of Contents
1. [Core Concepts, Mains vs. Alts, & Rules](#1-core-concepts-mains-vs-alts--rules)
2. [One-Time Google Sheet Setup](#2-one-time-google-sheet-setup)
3. [Multiple Concurrent Raids (Up to 4 Raids)](#3-multiple-concurrent-raids-up-to-4-raids)
4. [Weekly Operating Procedure (End-to-End Flow)](#4-weekly-operating-procedure-end-to-end-flow)
   - [Phase A: Pre-Raid Setup](#phase-a-pre-raid-setup)
   - [Phase B: During the Raid (In-Game Roll-Offs)](#phase-b-during-the-raid-in-game-roll-offs)
   - [Phase C: Post-Raid Sheet Processing & Won-Items Export](#phase-c-post-raid-sheet-processing--won-items-export)
5. [Complete Command & Menu Reference](#5-complete-command--menu-reference)
   - [A. Google Sheet Menu](#a-google-sheet-rolling-sr-menu)
   - [B. Loot Master Commands In-Game (`/rsr` & `/gl`)](#b-loot-master-master-looter--officer-commands-in-game)
   - [C. Raider / Player Commands In-Game](#c-player--raider-commands-in-game)
6. [Testing & Verification Guide](#6-testing--verification-guide)
   - [In-Game Solo Test Mode (No Sheet Needed)](#a-in-game-solo-test-mode-test-every-feature-without-a-raid-or-sheet)
   - [Automated CLI Test Suites](#b-automated-cli-test-suites)
7. [Supported Client Builds & `.toc` Maintenance](#7-supported-client-builds--toc-maintenance)
8. [FAQ & Edge Cases](#8-faq--edge-cases)

---

## 1. Core Concepts, Mains vs. Alts, & Rules

- **2 Soft Reserves (SRs) per player per week.**
- **Roll Accumulation & Configurable Cap:** Reserving the same item without winning it week-over-week on a **Main** grants **`+1` extra roll** for subsequent weeks, up to a configurable cap (default **`100`**, controlled via `MAX_EXTRA_ROLLS` in `RollingSR_Code.gs` and `/rsr max <num>` in-game).
- **Mains vs. Alts Rules:**
  1. **No Shared Rolls:** Alts and Mains have separate entries and never share accumulated rolls.
  2. **Configurable Alt Roll Accumulation (`ALTS_ACCRUE_ROLLS = false` by default):**
     - By default, characters with `Status = Alt` do not accumulate stacking bonus rolls (`0` bonus rolls, exported with an `*alt` tag).
     - If your guild decides in the future that Alts *can* accrue bonus rolls, set **`ALTS_ACCRUE_ROLLS = true`** at the top of `RollingSR_Code.gs` and toggle **`/rsr altrolls on`** in-game. Even with Alt bonus rolls enabled, Alts still **never win gear over Mains**—their bonus rolls only apply in Phase 2 when *no* Guild Main reserved the item.
  3. **Alt Attendance Protects Main's Streak:** If a player plays on their linked Alt instead of their Main—even for multiple weeks in a row—their Main's reserved items and accumulated rolls remain untouched and their Main accrues **`0` misses**.
  4. **Alts Never Win Over Mains, But Help Beat Pugs in Phase 1:**
     - When Pugs soft-reserve an item, Guild Alts can roll in **Phase 1**.
     - An Alt winning Phase 1 is treated identically to a Guild Main winning Phase 1: Pugs are eliminated and the roll-off advances to **Phase 2**.
     - In **Phase 2**, if *any* Guild Main reserved the item, **only Mains** are eligible to win (the Alt's Phase 1 roll cannot beat a Main). If *no* Guild Mains reserved the item, the Alt(s) can win it.
     - If *no* Pugs reserved the item and a Guild Main reserved it, Alts do not roll in Phase 1.
- **Recruit Trial Rules (2-Week Trial Period):**
  1. **Phase 1 Baseline Roll:** Recruits and Pugs are treated the same during Phase 1: everyone gets **1 baseline roll** (`/roll 1-100`).
  2. **Phase 2 Transition & Standing Roll:** If a recruit wins Phase 1 (or ties with a guild member), the roll-off advances to **Phase 2**.
     - In Phase 2, guild members roll their bonus rolls. Recruits roll with `+0` bonus rolls during their 2-week trial, but their **Phase 1 roll still counts**.
     - If no guild member beats the recruit's Phase 1 roll, the recruit wins the item.
  3. **Rolls Accrue in Background:** In both full guild runs and pug runs, recruits submit soft reserves and accrue `+1` bonus roll per week kept without winning. These rolls cannot be spent until their 2-week trial ends and an officer promotes them to Member.
- **Pug Isolation:** Pugs are never added to the Google Sheet. In-game, Gargul dynamically recognizes any player not in the guild export string as a Pug.
- **Two-Phase Rolling (No Timers — 100% Manual ML Control):**
  1. **Phase 1 (All Reserving Players):** Everyone who reserved the item gets **1 roll** (`/roll 1-100`).
     - **Pug Wins Outright:** The Pug has the highest roll. The item is awarded immediately (Phase 2 does not happen).
     - **Pug Ties with Guild Member/Alt/Recruit:** Gargul starts a tie-break round between the tied players only.
     - **Guild Member, Recruit, or Alt Wins (or Guild-Only Tie):** Gargul advances to **Phase 2**.
  2. **Phase 2 (Guild Players Only):** Eligible guild members roll only their bonus rolls (`ExtraRolls` bonus rolls in Phase 2; Phase 1 rolls stand as potential winning candidates). Guild members or recruits with `+0` bonus rolls do not roll in Phase 2, but their Phase 1 roll remains eligible to win. The highest valid roll across Phase 1 and Phase 2 wins.

### Streak, Status & Attendance Lifecycle
| Trigger / Status | Behavior |
|:---|:---|
| **Item Not Won (Kept)** | Gaining `+1` extra roll next week (capped at `MAX_EXTRA_ROLLS = 100`). |
| **Item Changed or Dropped** | Extra rolls reset to `0` for that slot. |
| **Item Won** | Extra rolls reset to `0` in Gargul upon award; export with **`/rsr won`** after raid to auto-update the sheet. |
| **1 Missed Raid** | Rolls preserved (1-week grace period); `Consecutive_Misses` set to `1`. |
| **2+ Consecutive Misses** | All extra rolls reset to `0`. |
| **Benched Status** | Marked as `Benched` before processing; keeps items, gains `+1` roll, accrues `0` misses. |
| **Excused Absence** | Officer runs **🌴 Excuse Absence / Vacation**; resets consecutive misses to `0` to protect streak. |
| **Recruit Trial Period** | Treated same as Pugs in Phase 1 (1 roll). If recruit wins Phase 1, moves to Phase 2 where their Phase 1 roll stands (0 bonus rolls). Extra rolls accrue in background and unlock after 2-week trial upon promotion to Member. |

---

## 2. One-Time Google Sheet Setup

### Step 1: Install the Google Apps Script
1. Open your Google Sheet and click **Extensions → Apps Script**.
2. Replace any code in `Code.gs` with the full contents of [`Scripts/RollingSR_Code.gs`](Scripts/RollingSR_Code.gs).
3. Press **Save** (`Ctrl + S`) and reload your Google Sheet tab.
4. A custom **Rolling SR** menu will appear in the top toolbar.

### Step 2: One-Click Tab Initialization
Click **Rolling SR → 🚀 Initialize / Repair Sheet Tabs** (or run `setupAllTabs` directly from the Apps Script editor dropdown). This automatically creates and formats all 4 tabs:

1. **`Roster_And_Rolls` (Guild Roster Only):**
   - Headers: `PlayerName | Status | Item_1_Name | Item_1_ExtraRolls | Item_2_Name | Item_2_ExtraRolls | Consecutive_Misses | Last_Raid_Date`
   - Column A: Guild character names (Title Case, e.g., `Thrall`, `Jaina`, `Dyalalt`).
   - Column B: Dropdown with allowed statuses (`Member`, `Recruit`, `Alt`, `Benched`).
   - **Linking an Alt to a Main (1-Click or Manual):** Click **Rolling SR → 🔗 Register / Link Alt to Main** to automatically add the Alt to both `Roster_And_Rolls` (`Status = Alt (MainName)`) and `Aliases` (`AltName | MainName | Alt`), or enter them manually on the sheets.
   - **Never list Pugs here.**
2. **`CSV_Import`:**
   - Headers: `Name | Class | ItemId | ItemName | Note | Plus`
   - Where officers paste the weekly SoftRes.it CSV export.
3. **`Addon_Export`:**
   - Cell **A1** holds the plain-text export string for Gargul (do not place formulas in `A1`).
   - Cell **A3** is an optional box where you can paste the in-game **`/rsr won`** string before clicking **⚡ Process Weekly SRs (Commit)** to automatically clear won items.
4. **`Aliases`:**
   - Headers: `Alias_Or_Alt_Name | Roster_Character_Name | Type` (with an `Alt` / `Alias` dropdown in Column C).
   - Maps alt characters (to protect their Main's streak while keeping the Alt's own soft reserves separate), nicknames, or common SoftRes typos back to a player's primary roster name.
   - *Note: Accented characters (`é`, `ö`, `ë`, `î`) are matched to unaccented SoftRes entries automatically.*

---

## 3. Multiple Concurrent Raids (Up to 4 Raids)

The system supports up to 4 raids running simultaneously:

1. **In-Game (WoW & Gargul):**
   - WoW chat channels (`/raid`, `/rw`) and roll tracking (`CHAT_MSG_SYSTEM`) are scoped to each specific raid group. Roll-offs in Raid 1 never interfere with Raids 2, 3, or 4.
   - One officer imports `Addon_Export!A1` via `/rsr <string>` and Gargul automatically broadcasts it to all Master Looters in the guild/raid.
2. **Post-Raid (Google Sheet):**
   - Either paste all SoftRes CSV exports stacked into `CSV_Import` (repeated headers are ignored automatically), or create separate tabs named `CSV_Raid1`, `CSV_Raid2`, `CSV_Raid3`, `CSV_Raid4`.
   - Running **⚡ Process Weekly SRs (Commit)** merges all `CSV_*` tabs in one batch so anyone who attended *any* raid is marked present.

---

## 4. Weekly Operating Procedure (End-to-End Flow)

```
[Phase A: Pre-Raid]
  1. Mark Benched raiders in Roster_And_Rolls (or Excuse Absences)
  2. Copy Addon_Export!A1 (or click "Rolling SR > View / Copy Addon String")
  3. Import in-game via "/rsr <string>" or "/gl sr" (auto-broadcasts to all MLs!)
                 │
                 ▼
[Phase B: During the Raid]
  1. Item drops → Alt + Click item to start Roll-Off in Gargul
  2. Phase 1: Watch "Phase 1: X/Y rolled" → Click "Stop Phase 1"
     • Pug wins outright → Award item (Done)
     • Pug ties → Tie-break round → Click "End Tie-Break"
     • Guild Main or Alt wins → Auto-starts Phase 2
  3. Phase 2: Watch "Phase 2: X/Y (All in!)" → Click "Stop Phase 2"
  4. Click "Award" → Winner's extra rolls auto-reset to 0 & logged in /rsr won
                 │
                 ▼
[Phase C: Post-Raid]
  1. Run "/rsr won" in-game and copy the won-items string
  2. Paste softres.it CSV(s) into CSV_Import (and optional "/rsr won" string into Addon_Export!A3)
  3. Click "Rolling SR > Preview & Review (Dry Run)"
  4. Click "Rolling SR > Process Weekly SRs (Commit)" (or "Import Won Items String")
```

### Phase A: Pre-Raid Setup
1. **Bench Check:** In `Roster_And_Rolls`, set Column B (`Status`) to **`Benched`** for any benched guild members.
2. **Copy Export String:** Copy Cell `A1` from `Addon_Export` (or click **Rolling SR → 📋 View / Copy Addon String**).
3. **Import In-Game:**
   - Run `/rsr <pasted_string>` **OR** open `/gl sr` and paste the SoftRes CSV and Rolling SR string into the Importer window.
   - Gargul **automatically broadcasts** the imported Rolling SR data to your raid group or guild, syncing all other Master Looters instantly.
4. **Raider Self-Service Whispers:**
   - Raiders can whisper `!rsr`, `!rolls`, or `!sr` to the Master Looter at any time to receive an automatic whisper reply with their reserved items and Phase 2 roll counts.

### Phase B: During the Raid (In-Game Roll-Offs)
1. **Tooltip Verification:** Hovering any soft-reserved item shows each player's status:
   - `Thrall (+2 bonus)` (Green — Main with bonus rolls)
   - `Jaina (+0)` (Gray — Main with 0 bonus rolls)
   - `Dyalalt (Alt)` (Light Blue — Guild Alt)
   - `PugWarrior (Pug)` (Orange — Pug)
2. **Phase 1 (All Reserving Players):**
   - Alt + Left-Click the item in the boss loot window (or your bags). The ML window displays `Phase 1: X/Y rolled` in real time and sets the stop button to **`Stop Phase 1`**.
   - Click **`Stop Phase 1`** when rolls are in:
     - **Pug Wins Outright:** Gargul announces the Pug winner and ends the roll-off.
     - **Pug Ties:** Gargul announces a tie-break round (`Tie-Break: X/Y rolled`) and changes the button to **`End Tie-Break`**.
     - **Guild Main or Alt Wins:** Gargul transitions to **Phase 2**.
3. **Phase 2 (Guild Players Only):**
   - Gargul announces Phase 2 and prints each eligible guild member's bonus roll allowance (with Phase 1 rolls standing). If any Main reserved the item, Alts cannot roll or win in Phase 2.
   - The ML window tracks bonus rolls live (`Phase 2: X/Y (All in!)`).
   - Click **`Stop Phase 2`** when complete, then click **`Award`**. Gargul resets the winner's extra rolls for that item to `0` and logs the award for `/rsr won`.

### Phase C: Post-Raid Sheet Processing & Won-Items Export
1. At the end of the raid, type **`/rsr won`** in-game to copy the compact won-items string (`Player1:Item1;Player2:Item2;`).
2. Export the SoftRes.it CSV(s) after raid and paste into `CSV_Import` (or `CSV_Raid1..4`).
3. *(Optional)* Paste the `/rsr won` string into **`Addon_Export!A3`** (or run **Rolling SR → 📥 Import Won Items String (/rsr won)** at any time).
4. Click **Rolling SR → 🔍 Preview & Review (Dry Run)** to inspect attendance, Alt-protected Mains, and any unmatched names.
5. Click **Rolling SR → ⚡ Process Weekly SRs (Commit)**:
   - Automatically saves a timestamped backup tab (`Archive_YYYY-MM-DD`).
   - Updates all roll streaks, protects Mains whose Alt attended, applies any won-items string in `Addon_Export!A3`, and refreshes `Addon_Export!A1` for next week.

---

## 5. Complete Command & Menu Reference

### A. Google Sheet `Rolling SR` Menu
| Menu Item | Description |
|:---|:---|
| **🔍 Preview & Review (Dry Run)** | Previews attendance, Alt-protected Mains, alias matches, absent members, and unmatched names without modifying data. |
| **⚡ Process Weekly SRs (Commit)** | Auto-creates an `Archive_YYYY-MM-DD` backup, updates streaks/misses, auto-applies `Addon_Export!A3` won items, and writes `Addon_Export!A1`. |
| **📋 View / Copy Addon String** | Displays the ready-to-copy `/rsr <string>` command in a popup modal. |
| **📥 Import Won Items String (/rsr won)** | Paste the `/rsr won` string from Gargul to automatically clear won item slots and reset their extra rolls to `0`. |
| **🏆 Mark Item Won (Manual)** | Interactive dialog to manually select a player and reset a won item slot to `0`. |
| **🔗 Register / Link Alt to Main** | Prompts for an Alt name and Main name, then automatically configures the Alt on `Roster_And_Rolls` (`Alt (MainName)`) and `Aliases` (`AltName \| MainName \| Alt`). |
| **🌴 Excuse Absence / Vacation** | Resets a player's `Consecutive_Misses` to `0` when they have an excused absence. |
| **🎓 Check Recruit Graduation** | Finds recruits who completed their 2-week trial and promotes them to `Member` with one click. |
| **📊 Streak Leaderboard & Stats** | Shows roster breakdown, top active bonus roll streaks, and raiders at risk of reset (`1 miss`). |
| **📢 Generate Discord Summary** | Generates a Discord markdown block listing all active player streaks. |
| **🚀 Initialize / Repair Sheet Tabs** | Creates/repairs all 4 tabs, headers, Status dropdowns, and clears formula errors in `Addon_Export!A1`. |
| **📦 Create Backup Snapshot** | Manually creates a timestamped `Archive_YYYY-MM-DD` copy of `Roster_And_Rolls`. |
| **🧹 Clean & Sort Roster** | Removes blank rows, normalizes Title Case and item spacing, and sorts the roster alphabetically. |
| **📋 Setup Aliases Tab** | Creates/verifies the `Aliases` tab (`Alias_Or_Alt_Name \| Roster_Character_Name \| Type`). |
| **🔄 Refresh Addon Export** | Rebuilds `Addon_Export!A1` from the current `Roster_And_Rolls` state. |

---

### B. Loot Master (Master Looter / Officer) Commands In-Game

#### 1. Rolling SR Commands (`/rsr` — All 1–2 Words!)
*(Note: `/gl rsr ...` also works as a legacy alias for `/rsr ...`)*

| Command | Description |
|:---|:---|
| **`/rsr`** | Shows loaded player count, max roll cap, Alt bonus roll state, and command list. |
| **`/rsr <string>`** | Imports the `Addon_Export!A1` string and auto-broadcasts to raid/guild. |
| **`/rsr list`** | Lists all loaded guild Mains, Alts, and their stored bonus rolls in chat. |
| **`/rsr <player>`** | Checks stored bonus rolls & Main/Alt/Pug status for a player (e.g. `/rsr Thrall`). |
| **`/rsr won`** | Displays & opens a copyable dialog with the session's won-items string (`Player:Item;`) for Google Sheets. |
| **`/rsr clearwon`** | Clears only the session's won-items export log. |
| **`/rsr sync`** | Manually broadcasts loaded bonus rolls to your raid group or guild. |
| **`/rsr guild`** | Manually broadcasts loaded bonus rolls specifically to guild Master Looters. |
| **`/rsr raid`** | Manually broadcasts loaded bonus rolls specifically to raid/group Master Looters. |
| **`/rsr max <num>`** | Views or updates the maximum accumulated extra rolls cap (default `100`). |
| **`/rsr altrolls`** | Toggles whether Alts can accrue/spend bonus rolls when no Main reserved (`on` / `off`). |
| **`/rsr clear`** | Clears all stored Rolling SR data and won-item logs. |
| **`/rsr test`** | Enables solo in-game test mode with two Vanilla Molten Core items (`18832` and `18820`). |
| **`/rsr sim`** | Simulates standard rolls during an active test roll-off (Phase 1, Tie-Break, or Phase 2). |
| **`/rsr simpug`** | Simulates a Pug rolling `99` in Phase 1 to test Pug winning Phase 1 outright. |
| **`/rsr simalt`** | Simulates an Alt rolling `97` over a Pug in Phase 1 to test Alt triggering Phase 2. |
| **`/rsr tie`** | Simulates a Phase 1 tie (`95`) between a Pug and Guild member/Alt to test tie-breaker rounds. |
| **`/rsr simwon`** | Simulates awarding the item to test extra-roll reset and `/rsr won` without needing a boss corpse. |

#### 2. Gargul Master Looter Commands (`/gl`)
| Command | Shorthand | Description |
|:---|:---|:---|
| **`/gl rolloff [item]`** | **`/gl ro [item]`** | Opens the Master Looter Roll-Off window (accepts an item link or numeric item ID, e.g., `/gl ro 18832`). |
| **`/gl softreserves`** | **`/gl sr`** | Opens the SoftRes Importer (paste SoftRes CSV + Rolling SR string) or SoftRes Overview window. |
| **`/gl award [winner] [item]`**| **`/gl a`** | Opens the Award window or directly awards an item to a player. |
| **`/gl awardondate`** | **`/gl aod`** | Retroactively awards an item on a specific date: `/gl aod [winner] [yy-mm-dd] [itemLink]`. |
| **`/gl awardhistory`** | **`/gl ah`** | Opens the Award History window showing all awarded items and rolls. |
| **`/gl plusones`** | **`/gl po`** / **`/gl +1`** | Opens the `+1` tracker window to view and edit player `+1` values. |
| **`/gl clearplusones`** | **`/gl cpo`** | Clears all `+1` values. |
| **`/gl boostedrolls`** | **`/gl br`** | Opens the standard Gargul Boosted Rolls UI. |
| **`/gl packmule`** | **`/gl pm`** | Opens PackMule settings to auto-loot/funnel specific items (e.g., greens/materials). |
| **`/gl setdisenchanter [name]`**| **`/gl sd [name]`** | Directly assigns the raid's disenchanter for auto-distribution. |
| **`/gl cleardisenchanter`** | **`/gl cd`** | Clears the assigned disenchanter. |
| **`/gl import`** | **`/gl im`** | Opens the general Importer hub (SoftRes, TMB, Loot Priority). |
| **`/gl export`** | **`/gl ex`** | Exports dropped/awarded loot to CSV format. |
| **`/gl groups`** | **`/gl gr`** | Opens the Raid Groups manager to check missing members and sort groups. |
| **`/gl raidcsv`** | **`/gl rcsv`** | Outputs everyone currently in the raid group in CSV format. |
| **`/gl inspect [itemIDs]`** | **`/gl ins`** | Checks whether raid members brought specific items/consumables. |
| **`/gl version`** | **`/gl ve`** | Compares Gargul versions across the raid group. |
| **`/gl lootpriority`** | **`/gl lo`** / **`/gl pr`** | Opens the Loot Priority editor (`thatsmybis` / `/gl tmb`, `/gl dft`, `/gl cpr`, `/gl rrobin`). |
| **`/gl gdkp`** | **`/gl gd`** | Opens the GDKP session manager (`/gl au` for auctioneer, `/gl ma` for multi-auction, `/gl ip` for prices). |
| **`/gl settings`** | **`/gl co`** / **`/gl config`**| Opens the Gargul configuration menu. |

---

### C. Player / Raider Commands In-Game

Players in the raid can use the following whispers, rolls, and slash commands at any time:

#### 1. Whisper Commands (Send to the Master Looter)
| Whisper Command | Aliases | What the Player Receives Back |
|:---|:---|:---|
| **`!rsr`** | **`!rolls`**, **`!rollingsr`** | Automatic whisper showing their status (**Guild Main**, **Guild Alt**, or **Pug**) and each soft-reserved item with its accumulated bonus rolls in Phase 2 (while Phase 1 rolls stand). |
| **`!sr`** | **`!softres`**, **`!softreserve`** | Automatic whisper showing the exact item links they soft-reserved this week along with their `(+X bonus)` or `(Alt)` badge. |

#### 2. Rolling Commands (During an Active Roll-Off)
| Command | When to Use |
|:---|:---|
| **`/roll`** (or **`/roll 1-100`**) | **Main Spec / Soft Reserve Roll (`1-100`):** Used by all reserving players once in **Phase 1**, by tied players in a **Tie-Break Round**, and by eligible Guild players casting their bonus rolls in **Phase 2** (or click the **Main Spec** roll button in Gargul's popup Roll window). |
| **`/roll 99`** (or **`/roll 1-99`**) | **Off-Spec Roll (`1-99`):** Used for Off-Spec rolls on open/unreserved items (or click the **Off Spec** button in Gargul's Roll window). |

#### 3. Player UI Slash Commands (`/gl`)
| Command | Shorthand | Description |
|:---|:---|:---|
| **`/gl rolls`** | — | Reopens the active (or most recent) Roll-Off popup window if closed accidentally. |
| **`/gl sr`** | **`/gl so`** | Opens the Soft Reserves overview window so raiders can browse all raid soft reserves. |
| **`/gl ah`** | **`/gl awardhistory`**| Opens the Award History window to review items awarded during the raid. |
| **`/gl ar`** | **`/gl autoroll`** | Opens Auto-Roll rules to automatically roll Need/Greed/Pass on non-SR items. |
| **`/gl ge`** | **`/gl gear`** | Opens the Worn Gear comparison window. |
| **`/gl bid`** | — | Opens the bidding window during a GDKP multi-auction. |
| **`/gl minimap`** | — | Opens minimap button visibility and position settings. |
| **`/gl start`** | **`/gl go`** | Opens the Gargul Quick Start guide. |
| **`/gl resetui`** | — | Resets all Gargul window positions and sizes if a frame goes off-screen. |
| **`/gl resetsettings`**| — | Resets all Gargul settings to factory defaults. |
| **`/gl bug`** | **`/gl bugreport`** | Generates a diagnostic string for bug reports. |

---

## 6. Testing & Verification Guide

### A. In-Game Solo Test Mode (Test Every Feature Without a Raid or Sheet!)

You can test **every single feature** of Rolling SR solo in-game in under a minute. Start by enabling test mode:

```text
/rsr test
```

This loads two Vanilla Molten Core Soft Reserve items into Gargul (compatible with all WoW clients including Vanilla / Classic Era / WoW Forever `16001`):
1. **`[Brutality Blade]` (`18832`) — Mains + Alt + Pug:**
   - **You (Main):** `+2` bonus rolls (`3` total rolls in Phase 2)
   - **Guildmate (Main):** `+1` bonus roll (`2` total rolls in Phase 2)
   - **Guildalt (Alt):** `+0` bonus rolls by default (`+1` if `/rsr altrolls` is toggled ON)
   - **Pugman (Pug):** Dynamic Pug (Phase 1 only, `0` bonus rolls)
2. **`[Talisman of Ephemeral Power]` (`18820`) — Alt + Pug Only (No Mains):**
   - **Guildalt (Alt):** `+0` bonus rolls by default (`+2` if `/rsr altrolls` is toggled ON)
   - **Pugman (Pug):** Dynamic Pug (Phase 1 only)

#### Scenario 1: Standard Main + Alt + Pug Roll-Off (Phase 1 → Phase 2)
1. Start roll-off: `/gl ro 18832`
2. Roll & simulate Phase 1: `/roll 1-100` then `/rsr sim` *(simulates `Pugman (72)`, `Guildalt (88)`, `Guildmate (85)`)*
3. Click **`Stop Phase 1`** → Guild wins Phase 1, advancing to **Phase 2**!
4. Roll your 3 Phase 2 rolls (`/roll 1-100` three times) and run `/rsr sim` *(simulates `Guildmate` rolling `94`; note that `Guildalt` is blocked from beating Mains in Phase 2)*.
5. Click **`Stop Phase 2`** → Highest Main roll wins!

#### Scenario 2: Pug Wins Phase 1 Outright (`/rsr simpug`)
1. Start roll-off: `/gl ro 18832`
2. Simulate a Pug high roll: `/rsr simpug` *(simulates `Pugman` rolling `99` vs low Guild rolls)*
3. Click **`Stop Phase 1`** → `Pugman` wins Phase 1 outright and the roll-off ends immediately (no Phase 2).

#### Scenario 3: Phase 1 Tie-Breaker Between Pug & Guild (`/rsr tie`)
1. Start roll-off: `/gl ro 18832`
2. Simulate a tie: `/rsr tie` *(simulates `Pugman (95)` and `Guildmate (95)`)*
3. Click **`Stop Phase 1`** → Gargul announces a tie-break round (`Tie-Break: 0/2 rolled`, button changes to **`End Tie-Break`**).
4. Simulate tie-break rolls: `/rsr sim` *(simulates `Pugman (68)` and `Guildmate (89)`)*
5. Click **`End Tie-Break`** → `Guildmate` wins the tie-break and Gargul advances to **Phase 2**!

#### Scenario 4: Alt Wins Phase 1 vs. Pug → Triggers Phase 2 for Mains (`/rsr simalt`)
1. Start roll-off: `/gl ro 18832`
2. Simulate Alt topping Phase 1: `/rsr simalt` *(simulates `Guildalt (97)`, `Pugman (80)`, `Guildmate (45)`)*
3. Click **`Stop Phase 1`** → `Guildalt` eliminates `Pugman` and triggers **Phase 2**!
4. In Phase 2, roll on your Main (`/roll 1-100`) and click **`Stop Phase 2`** → Your Main or `Guildmate` wins (even if lower than `97`), proving an Alt's Phase 1 roll can never beat a Main!

#### Scenario 5: Alt-Only vs. Pug Item & Configurable Alt Bonus Rolls (`/rsr altrolls` + `/gl ro 18820`)
1. Enable Alt bonus rolls: `/rsr altrolls on`
2. Start roll-off on the Alt+Pug item: `/gl ro 18820`
3. Simulate Phase 1: `/rsr sim` *(simulates `Pugman (72)` and `Guildalt (88)`)*
4. Click **`Stop Phase 1`** → Because **no Main** reserved `18820`, `Guildalt` advances to Phase 2 with **`3` rolls (`2` extra)**!
5. Simulate Phase 2: `/rsr sim`, then click **`Stop Phase 2`** → `Guildalt` wins!
6. Turn Alt bonus rolls back to default: `/rsr altrolls off`

#### Scenario 6: Awarding & `/rsr won` Export String (`/rsr simwon`)
1. Run `/rsr simwon` (or click **`Award`** in the Master Looter window when looting a boss).
2. Notice the winner's extra rolls for that item automatically reset to `0` (verify with `/rsr list`).
3. Run **`/rsr won`** → Opens the copyable dialog with the won-items export string (`Guildmate:Brutality Blade;`).

#### Scenario 7: Raider Whisper Auto-Replies (`!rsr` / `!rolls` / `!sr`)
1. Whisper yourself in-game: `/w YourCharacterName !rsr` and `/w YourCharacterName !sr`
2. Verify you immediately receive the automated whisper response with your reserved items and bonus roll counts.
3. When finished testing, clean up with: `/rsr clear`

---

### B. Automated CLI Test Suites

Run these commands from the repository root (`c:\Users\quick\dyal-gargul`) in PowerShell to verify all code and business logic offline:

#### 1. Validate Lua 5.1 Syntax Across All Addon Files (163 Files)
Uses the bundled Lua 5.1 interpreter (`Scripts\bin\lua5.1.exe`) to compile and verify syntax for every `.lua` file in the addon:
```powershell
.\Scripts\bin\lua5.1.exe .\Scripts\validate_lua.lua
```

#### 2. Run Rolling SR Addon Unit Tests (27 Test Suites)
Tests string parsing, Phase 1 gating, Pug outright wins, single and multi-round tie-breaks, guild-only ties, Phase 2 roll caps, winner determination, award roll resets, `/rsr won` award export strings, Mains vs. Alts Phase 1 & Phase 2 rules, configurable Alt roll accumulation (`/rsr altrolls`), configurable max roll cap (`/rsr max`), live UI counters, 1–2 word `/rsr` commands, auto-broadcasting, `!rsr`/`!rolls` whispers, Unicode quote normalization, and all solo test simulator modes (`/rsr test`, `/rsr simpug`, `/rsr simwon`):
```powershell
.\Scripts\bin\lua5.1.exe .\Scripts\test_rolling_sr.lua
```

#### 3. Run Google Sheet Business Logic & Syntax Tests (41 Assertions)
Tests roll accumulation (`+1`), item change/drop resets, 1-miss grace period, 2-miss resets, benched attendance, Pug filtering, multi-raid CSV merging, accent stripping, alias resolution, recruit 2-week trial gating, manual and automated `/rsr won` item resets, excused absences, roster cleaning/sorting, Mains vs. Alts multi-week streak protection & `*alt` exports, configurable `ALTS_ACCRUE_ROLLS`, `MAX_EXTRA_ROLLS = 100` cap, and live brace/parenthesis/bracket syntax validation of `Scripts/RollingSR_Code.gs`:
```powershell
powershell -ExecutionPolicy Bypass -File .\Scripts\test_sheets_logic.ps1
```

---

## 7. Supported Client Builds & `.toc` Maintenance

[`Gargul.toc`](Gargul.toc), [`Gargul_ItemData/Gargul_ItemData.toc`](Gargul_ItemData/Gargul_ItemData.toc), and [`Data/Constants.lua`](Data/Constants.lua) are configured for the latest client builds:

| Client Flavor | Installed Build Version | `.toc` Interface Number |
|:---|:---|:---|
| **WoW Classic Beta / Forever (`_classic_beta_`)** | `1.60.1.70425` | **`16001`** (`Interface`, `Interface-Camelot`, `Interface-Beta`) |
| **WoW Classic Era (`_classic_era_`)** | `1.15.9.70003` | **`11509`** (`Interface`, `Interface-Classic`) |
| **WoW Anniversary / BCC** | `2.5.6.70006` | **`20506`** (`Interface`, `Interface-BCC`) |
| **WoW Retail (`_retail_`)** | `12.1.5.70391` | **`120105`** (`Interface`) |

If a future patch increments the client interface number:
1. Check the client's interface number in-game by running:
   ```text
   /run print((select(4, GetBuildInfo())))
   ```
2. Open [`Gargul.toc`](Gargul.toc) and [`Gargul_ItemData/Gargul_ItemData.toc`](Gargul_ItemData/Gargul_ItemData.toc) and add the number to `## Interface:`, `## Interface-Camelot:`, and `## Interface-Beta:`.

---

## 8. FAQ & Edge Cases

#### What happens if an Alt beats a Pug in Phase 1 while a Main also reserved the item?
The Alt's high roll in Phase 1 eliminates the Pug and advances the roll-off to Phase 2 (just like a regular guild member winning Phase 1). In Phase 2, because Alts can never win gear over Mains, only the Main(s) who reserved the item compete in Phase 2 and the Alt's Phase 1 roll is excluded from winning over the Main.

#### What happens if a player plays on their Alt for several weeks in a row?
Link their Alt to their Main in the `Aliases` tab (`AltName | MainName`) or set their Alt's Status to `Alt (MainName)` in `Roster_And_Rolls`. Whenever their Alt attends the raid, their Main's reserved items and accumulated bonus rolls are preserved untouched and their Main's `Consecutive_Misses` stays at `0`.

#### What happens if a Pug ties with a Guild Main or Alt in Phase 1?
Gargul launches a tie-break round between the tied players only. If the Pug wins the tie-break, the Pug wins the item outright (no Phase 2). If the Guild Main or Alt wins the tie-break, Gargul transitions to Phase 2.

#### What happens if two Guild members tie in Phase 1 (with no Pug tied)?
Gargul skips the Phase 1 tie-break and advances directly to Phase 2, where guild members use their bonus rolls.

#### What happens if a player rolls more than their allowed count in Phase 2?
Gargul enforces the exact bonus roll limit (`ExtraRolls`) per player in Phase 2 and automatically ignores any extra `/roll` spam beyond their limit.
