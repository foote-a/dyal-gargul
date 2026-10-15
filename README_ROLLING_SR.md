# Rolling SR — System & User Guide

A custom loot system for World of Warcraft raids integrating **Google Sheets** and a custom **Gargul** addon fork. It rewards raid consistency by allowing guild members to accumulate bonus rolls on reserved items week-over-week, while ensuring fair, competitive rolling alongside Pugs.

---

## Table of Contents
1. [Core Concepts](#core-concepts)
2. [Google Sheet Setup (One-Time)](#google-sheet-setup-one-time)
3. [Multiple Concurrent Raids (Up to 4 Raids)](#multiple-concurrent-raids-up-to-4-raids)
4. [Weekly Operating Procedure](#weekly-operating-procedure)
   - [Step 1: Pre-Raid Bench Check](#step-1-pre-raid-bench-check)
   - [Step 2: Addon Setup (In-Game MLs)](#step-2-addon-setup-in-game-mls)
   - [Step 3: During the Raid (Roll-Off Rules)](#step-3-during-the-raid-roll-off-rules)
   - [Step 4: Post-Raid Sheet Processing](#step-4-post-raid-sheet-processing)
5. [Rules & Mechanics Reference](#rules--mechanics-reference)
6. [FAQ & Edge Cases](#faq--edge-cases)

---

## Core Concepts

- **2 Soft Reserves (SRs) per player per week.**
- **Roll Accumulation:** Reserving the same unwon item week-over-week grants +1 extra roll for subsequent weeks.
- **Pug Isolation:** Pugs are never tracked in the Google Sheet. The sheet roster contains only guild members. In-game, Gargul dynamically recognizes any reservist not in the guild export string as a Pug.
- **Two-Phase Rolling:**
  - **Phase 1 (All reservists — Guild & Pugs):** Everyone gets 1 roll (`/roll 1-100`). If a Pug wins outright, the item is awarded immediately (no Phase 2). If a Pug ties, an automatic tie-break roll occurs. If a Guild member wins, Gargul advances to Phase 2.
  - **Phase 2 (Guild reservists only):** Guild members use their accumulated extra rolls (`1 + ExtraRolls` total rolls). The highest roll across Phase 1 and Phase 2 wins.
- **No Timers:** The Master Looter (ML) retains 100% manual control over when Phase 1, Phase 2, and tie-break rounds stop by clicking Gargul's **Stop** button.

---

## Google Sheet Setup (One-Time)

### 1. Create Spreadsheet Tabs

#### A. CSV Import Tab(s)
You can choose either option depending on your guild's setup:
- **Dedicated Tabs per Raid (Recommended for up to 4 concurrent raids):**
  - Create tabs named: `CSV_Raid1`, `CSV_Raid2`, `CSV_Raid3`, `CSV_Raid4`.
  *(The script automatically scans all sheets whose names start with `CSV_`)*.
- **Single Tab:**
  - Create a single tab named `CSV_Import`. You can paste multiple softres CSV exports one below another in this tab (repeated header rows are automatically ignored).

#### B. `Roster_And_Rolls` (Guild Roster Only)
Create Row 1 with these 8 column headers:

| Col A | Col B | Col C | Col D | Col E | Col F | Col G | Col H |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **PlayerName** | **Status** | **Item_1_Name** | **Item_1_ExtraRolls** | **Item_2_Name** | **Item_2_ExtraRolls** | **Consecutive_Misses** | **Last_Raid_Date** |

- Fill Column A with your guild members' character names (Title Case, e.g. `Thrall`, `Jaina`).
- **Allowed Statuses:** `Member`, `Recruit`, `Alt`, `Benched`.
- **Do NOT list Pugs here.** The script skips unlisted players and reports them via a toast popup.

#### C. `Addon_Export`
Create an empty tab named `Addon_Export`. Cell **A1** is where the generated import string for Gargul will be written.

---

### 2. Install the Google Apps Script
1. In Google Sheets, open **Extensions → Apps Script**.
2. Replace any placeholder code with the contents of [`Scripts/RollingSR_Code.gs`](Scripts/RollingSR_Code.gs).
3. Save the script project (`Ctrl + S`).
4. Reload the Google Sheet. A new menu named **Rolling SR** will appear in the top toolbar.

---

## Multiple Concurrent Raids (Up to 4 Raids)

The system seamlessly supports up to 4 raids running at the exact same time:

1. **In-Game (WoW & Gargul):**
   - WoW chat channels (`/raid`, `/rw`) and system roll tracking (`CHAT_MSG_SYSTEM`) are strictly restricted to the specific raid instance and group.
   - Each raid has its own Master Looter running Gargul on their machine. Roll-offs and announcements in Raid 1 will never cross over or interfere with Raid 2, 3, or 4.
   - All Master Looters paste the exact same `Addon_Export!A1` string into their Gargul addon.
2. **Post-Raid (Google Sheet):**
   - Each raid team pastes their softres.it CSV into their designated tab (`CSV_Raid1`, `CSV_Raid2`, `CSV_Raid3`, `CSV_Raid4`).
   - When **Process Weekly SRs** is triggered, the script merges all raid exports in one batch. Anyone who raided in *any* of the 4 raids is marked present. Only members missing from *all* raids accrue an absence.

---

## Weekly Operating Procedure

```
[Pre-Raid: Mark Benched in Sheet]
               │
               ▼
[Copy Addon_Export!A1 to each ML's Gargul]
               │
               ▼
[Raid Time: Up to 4 Concurrent Raids Run Independently]
               │
               ▼
[Post-Raid: Paste softres CSVs into CSV_Raid1..4]
               │
               ▼
[Click "Rolling SR > Process Weekly SRs"]
               │
               ▼
[Addon_Export!A1 auto-refreshed for next week]
```

### Step 1: Pre-Raid Bench Check
- If an officer marks a guild member as benched, change their `Status` in `Roster_And_Rolls` column B to **`Benched`** before running the weekly script.
- Benched players keep their current reserved items, gain +1 roll on each, and accrue 0 misses.

---

### Step 2: Addon Setup (In-Game MLs)
Before the raid begins:
1. Ensure `dyal-gargul` is in `World of Warcraft/_classic_/Interface/AddOns/Gargul`.
2. Open Gargul's SoftRes window (`/gl sr`).
3. Import your raid's softres.it data so Gargul knows all reservists (Guild + Pugs).
4. Copy cell **`Addon_Export!A1`** from the Google Sheet and paste it into the **Rolling SR (Weekly Extra Rolls)** field in the SoftRes window.
5. Click **Import**. (Data persists across `/reload` and logouts in `GargulDB`).

---

### Step 3: During the Raid (Roll-Off Rules)

When an item reserved under Rolling SR drops:

#### Phase 1: All Reservists (Guild & Pugs)
1. Gargul announces Phase 1 to Raid Warning/Raid Chat: all reservists roll once (`/roll 1-100`).
2. **No Timers:** Gargul does not start a countdown. The ML clicks **Stop** when all reservists have rolled.
3. Resolution:
   - **Pug Wins Outright:** The Pug has the highest roll. Gargul announces the Pug as the winner. The roll-off finishes immediately (no Phase 2).
   - **Tie-Break Round:** If there is a tie for top roll (involving a Pug or Guild members), Gargul initiates an automatic tie-break round. Only tied players can roll. The ML clicks **Stop** once tied players have rolled.
   - **Guild Member Wins:** Gargul advances automatically to **Phase 2**.

#### Phase 2: Guild Members Only
1. Gargul announces Phase 2 and lists each eligible guild member's total allowed rolls (`1 + ExtraRolls`).
2. Eligible guild members cast their bonus `/roll 1-100` rolls.
   - Gargul accepts up to `1 + ExtraRolls` per player and automatically ignores excess rolls.
   - Pugs and non-reservists cannot roll in Phase 2.
3. **No Timers:** The ML clicks **Stop** when bonus rolls are in.
4. Gargul evaluates all valid rolls across Phase 1 and Phase 2 and announces the final winner.
5. **Auto-Reset:** Upon awarding the item via Gargul, the winning player's extra rolls on that item automatically reset to `0` in the addon.

---

### Step 4: Post-Raid Sheet Processing
1. When all raids conclude, export the softres.it CSVs.
2. Paste them into `CSV_Raid1`, `CSV_Raid2`, etc. (or stack them in `CSV_Import`).
3. In the top menu, select **Rolling SR → Process Weekly SRs**.
4. The script:
   - Merges all raid attendances.
   - Skips all Pugs and shows a toast notification summary.
   - Increments rolls (+1) for repeating reserved items.
   - Resets rolls (to 0) for changed/dropped items.
   - Enforces the 1-miss grace period and 2-consecutive-miss roll reset.
   - Accumulates recruit rolls internally (exported as 0 until 2 weeks pass).
   - Updates **`Addon_Export!A1`** with the new string for next week.

---

## Rules & Mechanics Reference

| Rule | Description |
|:---|:---|
| **Pug Handling** | Pugs are never placed in the sheet. In-game, Gargul recognizes any reservist not in the guild string as a Pug. Pugs win immediately if they win Phase 1 outright. |
| **Concurrent Raids** | Up to 4 raids run in parallel in-game with zero cross-talk. Sheet combines `CSV_Raid1..4` tabs in a single batch so attendance is correctly credited. |
| **Timers** | Completely disabled. Master Looters manually control Phase 1, Phase 2, and tie-break rounds using the Stop button. |
| **Same Item Reserved** | +1 extra roll accumulated for next week. |
| **Item Changed or Dropped** | Extra rolls reset to 0 for that slot. |
| **Item Won** | Automatically resets to 0 upon award in Gargul (or manually via `markItemWon("Player", "Item")` in the sheet). |
| **1 Missed Raid** | Rolls preserved; `Consecutive_Misses` set to 1. |
| **2+ Consecutive Misses** | All extra rolls reset to 0. |
| **Benched** | Marked as `Benched` before processing; keeps items, gains +1 roll, accrues 0 misses. |
| **Recruit Trial** | Extra rolls accumulate behind the scenes, but export as 0 until 2 weeks have elapsed. |

---

## FAQ & Edge Cases

#### What happens if a Pug ties with a Guild member in Phase 1?
Gargul automatically launches a tie-break round between the tied players only. If the Pug wins the tie-break, the Pug wins the item outright (no Phase 2). If the Guild member wins the tie-break, Gargul transitions to Phase 2 for bonus rolls.

#### What happens if a player rolls more than their allowed count in Phase 2?
Gargul tracks roll counts per player in Phase 2. Rolls beyond `1 + ExtraRolls` are discarded and do not count toward the results.

#### How do Alts work?
Set the player's status in `Roster_And_Rolls` column B to `Alt`. They accumulate rolls on reserved items identically to main raiders.
