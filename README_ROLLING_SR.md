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
Create an empty tab named `Addon_Export`. Cell **A1** is where the generated import string for Gargul will be written (leave this cell empty; do not put a formula here).

#### D. `Aliases` (Optional but Recommended)
Click **Rolling SR → 📋 Setup Aliases Tab** (or create a tab named `Aliases`):
- Column A: **`Alias_Or_Alt_Name`** (alt character name, Discord username, or common typo)
- Column B: **`Roster_Character_Name`** (the official character name in `Roster_And_Rolls`)
- *Why use this:* If a member signs into SoftRes under an alt or nickname, this maps them back to their primary roster character so they don't accrue an accidental absence.
- *Accent Normalization:* Accented characters (`é`, `ö`, `ë`) are automatically matched to unaccented SoftRes entries without needing manual alias rows.

---

### 2. Install the Google Apps Script
1. In Google Sheets, open **Extensions → Apps Script**.
2. Replace any placeholder code with the contents of [`Scripts/RollingSR_Code.gs`](Scripts/RollingSR_Code.gs).
3. Save the script project (`Ctrl + S`).
4. Reload the Google Sheet. A new menu named **Rolling SR** will appear in the top toolbar with:
   - **`🔍 Preview & Review (Dry Run)`** — Check attendance and view any unmatched names/typos safely without modifying data.
   - **`⚡ Process Weekly SRs (Commit)`** — Commit weekly attendance and update extra rolls.
   - **`📋 Setup Aliases Tab`** — Automatically generate the `Aliases` tab.
   - **`🔄 Refresh Addon Export`** — Rebuild `Addon_Export!A1`.

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
Before the raid begins, Master Looters can import the data in **one of three fast ways**:

- **Method A — Slash Command (Fastest):**  
  Type or paste directly in chat:  
  `/gl rsr <paste export string here>`
- **Method B — Addon Comms Sync (No Google Sheets needed for other MLs!):**  
  One officer imports the string, then types:  
  `/gl rsr broadcast` (or `/gl rsr broadcast guild`)  
  All other Master Looters running Gargul in the raid or guild will automatically receive and sync the data!
- **Method C — SoftRes Window:**  
  Open Gargul's SoftRes window (`/gl sr`), paste into the **Rolling SR (Weekly Extra Rolls)** field, and click **Import**.

*(Note: Data persists across `/reload` and logouts in `GargulDB`).*

---

### Step 3: During the Raid (Roll-Off Rules & ML Interface)

When an item reserved under Rolling SR drops:

#### Tooltip Inspection
Hovering over any item in bags or loot windows automatically lists reservists along with their bonus rolls:
> `Arthas (+2 bonus)`  
> `Thrall (+0)`  
> `PugWarrior (Pug)`

#### Phase 1: All Reservists (Guild & Pugs)
1. Gargul announces Phase 1 to Raid Warning/Raid Chat: all reservists roll once (`/roll 1-100`).
2. **Live Counter in ML Window:** The ML window displays:  
   `Phase 1: X/Y reservists rolled` in real-time as rolls arrive.
3. **Dynamic Button:** The stop button dynamically changes label to **`Stop Phase 1`**.
4. The ML clicks **`Stop Phase 1`** when all reservists have rolled:
   - **Pug Wins Outright:** The Pug has the highest roll. Gargul announces the Pug as the winner. The roll-off finishes immediately (no Phase 2).
   - **Tie-Break Round:** If there is a tie for top roll (involving a Pug or Guild members), Gargul initiates a tie-break round. The button changes to **`End Tie-Break`** and status shows `Tie-Break: X/Y rolled`. The ML clicks **`End Tie-Break`** once tied rolls are complete.
   - **Guild Member Wins:** Gargul advances automatically to **Phase 2**.

#### Phase 2: Guild Members Only
1. Gargul announces Phase 2 and lists each eligible guild member's total allowed rolls (`1 + ExtraRolls`).
2. **Live Counter in ML Window:** The status updates live to show bonus rolls cast:  
   `Phase 2: X/Y rolls` (and displays `(All in!)` when every eligible bonus roll has been cast).
3. **Dynamic Button:** The stop button dynamically changes to **`Stop Phase 2`**.
4. The ML clicks **`Stop Phase 2`** when bonus rolls are in.
5. Gargul evaluates all valid rolls across Phase 1 and Phase 2 and announces the final winner.
6. **Award Confirmation:** When the ML awards the item via Gargul, Gargul resets the player's rolls on that item to `0` and prints an immediate confirmation in chat:  
   `[Rolling SR] Betrayer of Humanity awarded to Arthas. Extra rolls reset to 0.`

---

### Step 4: Post-Raid Sheet Processing
1. When all raids conclude, export the softres.it CSVs.
2. Paste them into `CSV_Raid1`, `CSV_Raid2`, etc. (or stack them in `CSV_Import`).
3. *(Optional but Recommended)* Select **Rolling SR → 🔍 Preview & Review (Dry Run)**:
   - Verifies which guild members attended, lists absent members, and flags any unmatched names.
   - If an unmatched name is actually a guild member's alt or typo, add it to the **`Aliases`** tab.
4. Select **Rolling SR → ⚡ Process Weekly SRs (Commit)**:
   - If unmatched names exist, a confirmation dialog lists them to ensure no guild members are accidentally skipped.
   - The script merges all raid attendances across tabs.
   - Resolves alts and typos via the `Aliases` tab and automatically normalizes accented characters.
   - Skips all external Pugs.
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

## Raid Night Quick Reference Checklist

### 15 Minutes Before Raid
- [ ] **Officers:** Check if anyone is benched; set their status to `Benched` in column B of `Roster_And_Rolls`.
- [ ] **One Officer:** Copy `Addon_Export!A1` and run `/gl rsr <string>` in WoW.
- [ ] **Broadcast:** Run `/gl rsr broadcast guild` (or `/gl rsr broadcast` in raid) so all other Master Looters sync instantly.
- [ ] **Verify:** Type `/gl rsr` to confirm loaded player count.

### During the Raid (When an Item Drops)
1. **Start Roll-Off:** Alt-Click the item or click Start in Gargul.
2. **Phase 1:** Watch the live counter: `Phase 1: X/Y reservists rolled`.
3. **Stop Phase 1:** Click **`Stop Phase 1`** once all initial rolls are in.
   - *If Pug wins:* Done! Award item.
   - *If Tie:* Click **`End Tie-Break`** once tied players re-roll.
   - *If Guild member wins:* Advances automatically to Phase 2.
4. **Phase 2:** Watch the bonus counter: `Phase 2: X/Y rolls (All in!)`.
5. **Stop Phase 2:** Click **`Stop Phase 2`**.
6. **Award Item:** Select winner and click **`Award`**. A green chat confirmation will print: `[Rolling SR] <Item> awarded to <Player>. Extra rolls reset to 0.`

### Post-Raid (Officers)
- [ ] Download CSV export from softres.it for each raid team.
- [ ] Paste into `CSV_Raid1`, `CSV_Raid2`, etc.
- [ ] Click **Rolling SR → Process Weekly SRs** in Google Sheets.
- [ ] Confirm the toast summary (e.g. `Updated 45 guild members. Ignored 6 pug(s)`).

---

## FAQ & Troubleshooting

#### What happens if a Pug ties with a Guild member in Phase 1?
Gargul automatically launches a tie-break round between the tied players only. If the Pug wins the tie-break, the Pug wins the item outright (no Phase 2). If the Guild member wins the tie-break, Gargul transitions to Phase 2 for bonus rolls.

#### What happens if two Guild members tie in Phase 1?
If top rolls tie in Phase 1 and no Pug is involved (e.g. two guild members both roll 100), Gargul bypasses the Phase 1 tie-break and transitions directly to Phase 2, where both players can use their bonus rolls.

#### What happens if players tie again during a tie-break?
Gargul handles multiple consecutive tie-breaks automatically. If players tie in Round 1, Gargul increments to Round 2 and asks tied players to roll again.

#### What happens if an ML accidentally clicks "Stop Phase 1" too early?
Click the **`Clear`** button in the Master Looter UI. This resets the current roll-off so you can click **`Start`** to restart the roll-off fresh.

#### What if a dropped item wasn't soft-reserved by anyone?
If no guild member or pug reserved the item, Gargul's standard behavior takes over (e.g. normal MS > OS rolling or GDKP/auction, depending on your configuration). Rolling SR only activates when an item is tracked.

#### What happens if a player rolls more than their allowed count in Phase 2?
Gargul tracks roll counts per player in Phase 2. Excess rolls beyond `1 + ExtraRolls` are rejected by the addon engine and discarded from the roll table.

#### How do Alts work?
Set the player's status in `Roster_And_Rolls` column B to `Alt`. They accumulate rolls on reserved items identically to main raiders.

#### How do I manually reset or edit a player's rolls?
- **In-Game:** Re-importing a string via `/gl rsr <string>` updates rolls immediately. To wipe data, use `/gl rsr clear`.
- **In Google Sheets:** Run `markItemWon("PlayerName", "ItemName")` from the script editor or simply edit their roll count in column D/F of `Roster_And_Rolls`, then run `writeAddonExport()`.

---

---

## In-Game Solo Test Mode (No Google Sheet Needed!)

You can test the entire system completely solo in-game in 30 seconds without opening Google Sheets:

### 1. Enable Test Mode
Type in chat:
```
/gl rsr test
```
This automatically sets up:
- Mock Soft Reserves for **`[Deathbringer's Will]`** (Item ID: `50363`).
- **You:** +2 bonus rolls (3 rolls total in Phase 2).
- **Guildmate:** +1 bonus roll (2 rolls total in Phase 2).
- **Pugman:** Dynamic Pug (Phase 1 only, no bonus rolls).

### 2. Run a Simulated Roll-Off
1. Start the roll-off:
   ```
   /gl ro 50363
   ```
2. Roll for yourself:
   ```
   /roll 1-100
   ```
3. Simulate other players' rolls:
   ```
   /gl rsr sim
   ```
   *(Or type `/gl rsr sim tie` to simulate a tie between Pugman and Guildmate at 95 to test tie-breaks!)*
4. Watch the live counter in the Master Looter window:
   `Phase 1: 3/3 reservists rolled`
5. Click **`Stop Phase 1`**:
   - If tied with a Pug: the button changes to **`End Tie-Break`**. Type `/gl rsr sim` and click **`End Tie-Break`**.
   - If Guild member won Phase 1: advances automatically to Phase 2!
6. In Phase 2:
   - Roll your bonus rolls (`/roll 1-100`).
   - Type `/gl rsr sim` to simulate Guildmate's bonus roll.
   - Watch the counter reach `Phase 2: X/Y (All in!)`.
7. Click **`Stop Phase 2`**.
8. Select the winner and click **`Award`**:
   - Notice the green confirmation message in chat:
     `[Rolling SR] Deathbringer's Will awarded to <Winner>. Extra rolls reset to 0.`
9. Reset when finished:
   ```
   /gl rsr clear
   ```

---

## Automated Test Suites

The repository contains two automated test suites to verify functionality:

### 1. Addon Unit Tests (17 Tests)
Validates Phase 1 gating, tie-break rounds, Phase 2 bonus limits, Pug wins, item award resets, live counter calculations, solo test mode, slash commands, comms broadcast, Unicode UTF-8 quote normalization, and irregular whitespace parsing.
```powershell
Scripts\bin\lua5.1.exe scratch\test_rolling_sr.lua
```

### 2. Google Sheet Business Logic Tests (14 Tests)
Validates roll accumulation (+1), changed item resets, dropped item resets, 1-miss grace periods, 2-miss resets, bench attendance credits, Pug filtering, and multi-raid CSV merging.
```powershell
powershell -ExecutionPolicy Bypass -File Scripts\test_sheets_logic.ps1
```
