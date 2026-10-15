/**
 * Rolling SR — Google Apps Script for tracking per-item soft-reserve extra rolls.
 *
 * Sheet tabs:
 *   CSV_Import        — Officers paste raw softres.it CSV here.
 *   Roster_And_Rolls  — Master roster with accumulated extra rolls.
 *   Addon_Export       — Cell A1 holds the compressed import string for Gargul.
 *
 * Run processWeeklySoftReserves() after each raid to update everything.
 */

// ── Config ──────────────────────────────────────────────────────────────────────

/** Maximum soft reserves per player per week. */
var MAX_SR = 2;

/** Consecutive misses that reset all extra rolls to 0. */
var MISS_THRESHOLD = 2;

/** Weeks a recruit must attend before extra rolls can be spent. */
var RECRUIT_TRIAL_WEEKS = 2;

// ── Column indices (0-based) in Roster_And_Rolls ────────────────────────────────

var COL = {
  PLAYER:    0,  // A – PlayerName
  STATUS:    1,  // B – Member | Recruit | Alt | Pug
  ITEM1:     2,  // C – Item_1_Name
  ROLLS1:    3,  // D – Item_1_ExtraRolls
  ITEM2:     4,  // E – Item_2_Name
  ROLLS2:    5,  // F – Item_2_ExtraRolls
  MISSES:    6,  // G – Consecutive_Misses
  LAST_RAID: 7,  // H – Last_Raid_Date
};

var ROSTER_COLS = 8; // A through H

// ── Helpers ─────────────────────────────────────────────────────────────────────

/**
 * Return today as a YYYY-MM-DD string.
 */
function todayStamp() {
  return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyy-MM-dd");
}

/**
 * Normalise a player name: trim whitespace, Title Case.
 */
function normName(raw) {
  var s = (raw || "").toString().trim();
  if (!s) return "";
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
}

/**
 * Normalise an item name: trim, collapse internal whitespace.
 */
function normItem(raw) {
  return (raw || "").toString().trim().replace(/\s+/g, " ");
}

// ── CSV Parser ──────────────────────────────────────────────────────────────────

/**
 * Parse the softres.it CSV from the CSV_Import tab.
 * Expected columns (order detected from header): Name, Class, ItemId, ItemName, Note, Plus.
 *
 * Returns a map: { playerName: { items: [itemName, ...], class: string } }
 * Each item appears once per reservation (double-reserving the same item = two entries).
 */
function parseSoftresCSV() {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName("CSV_Import");
  if (!sheet) throw new Error("CSV_Import tab not found.");

  var data = sheet.getDataRange().getValues();
  if (data.length < 2) throw new Error("CSV_Import is empty or has no data rows.");

  // Detect header columns
  var header = data[0].map(function (h) { return h.toString().trim(); });
  var colIdx = {};
  header.forEach(function (h, i) { colIdx[h] = i; });

  var nameCol = colIdx["Name"];
  var itemCol = colIdx["ItemName"] !== undefined ? colIdx["ItemName"] : colIdx["Item Name"];
  var classCol = colIdx["Class"];

  if (nameCol === undefined || itemCol === undefined) {
    throw new Error("CSV header must contain 'Name' and 'ItemName' (or 'Item Name') columns.");
  }

  var players = {};
  for (var r = 1; r < data.length; r++) {
    var row = data[r];
    var pName = normName(row[nameCol]);
    var iName = normItem(row[itemCol]);
    if (!pName || !iName) continue;

    if (!players[pName]) {
      players[pName] = {
        items: [],
        class: classCol !== undefined ? row[classCol].toString().trim() : "",
      };
    }
    players[pName].items.push(iName);
  }

  return players;
}

// ── Roster helpers ──────────────────────────────────────────────────────────────

/**
 * Read the full Roster_And_Rolls sheet into a keyed object.
 * Returns { playerName: { row: <1-based row>, status, item1, rolls1, item2, rolls2, misses, lastRaid } }
 */
function readRoster(sheet) {
  var data = sheet.getDataRange().getValues();
  var roster = {};

  // Row 0 is header
  for (var r = 1; r < data.length; r++) {
    var row = data[r];
    var name = normName(row[COL.PLAYER]);
    if (!name) continue;

    roster[name] = {
      row: r + 1,  // 1-based sheet row
      status:   (row[COL.STATUS] || "").toString().trim(),
      item1:    normItem(row[COL.ITEM1]),
      rolls1:   parseInt(row[COL.ROLLS1], 10) || 0,
      item2:    normItem(row[COL.ITEM2]),
      rolls2:   parseInt(row[COL.ROLLS2], 10) || 0,
      misses:   parseInt(row[COL.MISSES], 10) || 0,
      lastRaid: (row[COL.LAST_RAID] || "").toString().trim(),
    };
  }

  return roster;
}

/**
 * Write a single player's data to their row.
 */
function writePlayerRow(sheet, sheetRow, name, status, item1, rolls1, item2, rolls2, misses, lastRaid) {
  sheet.getRange(sheetRow, 1, 1, ROSTER_COLS).setValues([[
    name, status, item1, rolls1, item2, rolls2, misses, lastRaid,
  ]]);
}

/**
 * Append a new player row at the bottom of the roster.
 */
function appendPlayerRow(sheet, name, status, item1, rolls1, item2, rolls2, misses, lastRaid) {
  sheet.appendRow([name, status, item1, rolls1, item2, rolls2, misses, lastRaid]);
}

// ── Core logic ──────────────────────────────────────────────────────────────────

/**
 * Main entry point. Call from the Apps Script editor or attach to a menu/button.
 *
 * Steps:
 *   1. Parse CSV_Import.
 *   2. Update Roster_And_Rolls (increment / reset extra rolls, track misses).
 *   3. Write the Gargul addon string to Addon_Export!A1.
 */
function processWeeklySoftReserves() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  if (!rosterSheet) throw new Error("Roster_And_Rolls tab not found.");

  var today = todayStamp();

  // ── 1. Parse this week's reserves ──
  var thisWeek = parseSoftresCSV(); // { playerName: { items:[], class } }

  // ── 2. Load existing roster ──
  var roster = readRoster(rosterSheet);

  // Build a set of all player names (union of roster + this week's CSV).
  var allPlayers = {};
  Object.keys(roster).forEach(function (n) { allPlayers[n] = true; });
  Object.keys(thisWeek).forEach(function (n) { allPlayers[n] = true; });

  // ── 3. Process each player ──
  Object.keys(allPlayers).forEach(function (name) {
    var prev = roster[name] || null;
    var curr = thisWeek[name] || null;

    // Normalise incoming items to exactly MAX_SR slots.
    var newItems = curr ? curr.items.slice(0, MAX_SR) : [];
    while (newItems.length < MAX_SR) newItems.push("");
    var newItem1 = newItems[0];
    var newItem2 = newItems[1];

    // Determine status — keep existing status; default new players to "Member".
    var status = prev ? prev.status : "Member";
    // If the CSV provided a class but the player is brand new, still default to Member.

    // ── Attendance / miss tracking ──
    if (curr) {
      // Player participated this week (present in CSV).
      var misses = 0; // reset consecutive misses on attendance
      var lastRaid = today;

      // ── Extra-roll calculation per slot ──
      var rolls1 = calcExtraRolls(prev, 1, newItem1, status);
      var rolls2 = calcExtraRolls(prev, 2, newItem2, status);

      if (prev) {
        writePlayerRow(rosterSheet, prev.row, name, status, newItem1, rolls1, newItem2, rolls2, misses, lastRaid);
      } else {
        appendPlayerRow(rosterSheet, name, status, newItem1, rolls1, newItem2, rolls2, misses, lastRaid);
      }
    } else if (prev) {
      // Player NOT in this week's CSV.
      var newMisses = prev.misses + 1;

      // If benched (officer marks status as "Benched"), treat as attending.
      if (prev.status === "Benched") {
        // Benched players keep their items, gain +1 roll each, and don't accumulate misses.
        var benchRolls1 = prev.item1 ? prev.rolls1 + 1 : 0;
        var benchRolls2 = prev.item2 ? prev.rolls2 + 1 : 0;
        writePlayerRow(rosterSheet, prev.row, name, prev.status,
          prev.item1, benchRolls1, prev.item2, benchRolls2, 0, today);
      } else {
        // Absent, non-benched player.
        if (newMisses >= MISS_THRESHOLD) {
          // 2+ consecutive misses: reset all extra rolls.
          writePlayerRow(rosterSheet, prev.row, name, prev.status,
            prev.item1, 0, prev.item2, 0, newMisses, prev.lastRaid);
        } else {
          // 1 miss: keep accumulated rolls intact.
          writePlayerRow(rosterSheet, prev.row, name, prev.status,
            prev.item1, prev.rolls1, prev.item2, prev.rolls2, newMisses, prev.lastRaid);
        }
      }
    }
  });

  // ── 4. Build and write the addon export string ──
  writeAddonExport(ss);
}

/**
 * Calculate extra rolls for a single item slot.
 *
 * @param {object|null} prev  Previous roster entry (null if new player).
 * @param {number}      slot  1 or 2.
 * @param {string}      newItem  The item name reserved this week (may be "").
 * @param {string}      status  Player's status (Member, Recruit, Alt, Pug).
 * @return {number}     Extra rolls to store.
 */
function calcExtraRolls(prev, slot, newItem, status) {
  if (!newItem) return 0; // No reservation → no extra rolls.

  var prevItem  = prev ? (slot === 1 ? prev.item1  : prev.item2)  : "";
  var prevRolls = prev ? (slot === 1 ? prev.rolls1 : prev.rolls2) : 0;

  // Check if misses were high enough to have already reset rolls.
  if (prev && prev.misses >= MISS_THRESHOLD) {
    prevRolls = 0;
  }

  if (prevItem === newItem) {
    // Same item reserved again — accumulate.
    return prevRolls + 1;
  }

  // Different item (or first time) — start fresh.
  return 0;
}

// ── Won-item handler ────────────────────────────────────────────────────────────

/**
 * Call this when a player wins their soft-reserved item.
 * Resets extra rolls for that item on the given player.
 *
 * @param {string} playerName  The winning player's name.
 * @param {string} itemName    The item they won.
 */
function markItemWon(playerName, itemName) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var roster = readRoster(sheet);

  var name = normName(playerName);
  var item = normItem(itemName);
  var entry = roster[name];
  if (!entry) return;

  if (entry.item1 === item) {
    sheet.getRange(entry.row, COL.ITEM1 + 1, 1, 2).setValues([["", 0]]);
  }
  if (entry.item2 === item) {
    sheet.getRange(entry.row, COL.ITEM2 + 1, 1, 2).setValues([["", 0]]);
  }
}

// ── Addon export ────────────────────────────────────────────────────────────────

/**
 * Build the Gargul addon import string and write it to Addon_Export!A1.
 *
 * Format: PlayerName:Item1=Rolls,Item2=Rolls;PlayerName:Item1=Rolls;
 *
 * Recruits still in their trial period have their available extra rolls
 * exported as 0 (they accumulate internally but can't spend them yet).
 */
function writeAddonExport(ss) {
  ss = ss || SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var exportSheet = ss.getSheetByName("Addon_Export");
  if (!exportSheet) {
    exportSheet = ss.insertSheet("Addon_Export");
  }

  var roster = readRoster(sheet);
  var parts = [];

  Object.keys(roster).forEach(function (name) {
    var e = roster[name];

    // Skip players with no active reservations.
    if (!e.item1 && !e.item2) return;

    // The addon treats everyone in this string as guild, so Pugs are left out.
    if (e.status === "Pug") return;

    // Determine if this player is a recruit still in trial.
    var recruitInTrial = isRecruitInTrial(e);

    var items = [];
    if (e.item1) {
      var r1 = recruitInTrial ? 0 : e.rolls1;
      items.push(e.item1 + "=" + r1);
    }
    if (e.item2) {
      var r2 = recruitInTrial ? 0 : e.rolls2;
      items.push(e.item2 + "=" + r2);
    }

    if (items.length > 0) {
      parts.push(name + ":" + items.join(","));
    }
  });

  var output = parts.join(";");
  if (output) output += ";";

  exportSheet.getRange("A1").setValue(output);
}

/**
 * Determine whether a player is a Recruit still within their 2-week trial
 * (i.e. they've attended fewer than RECRUIT_TRIAL_WEEKS raids).
 *
 * Heuristic: if status is "Recruit" AND lastRaid is within the trial window
 * (or they have very few recorded raids), treat them as in-trial.
 * Because the sheet only stores the last raid date (not total raid count),
 * we check whether their first recorded appearance was fewer than
 * RECRUIT_TRIAL_WEEKS weeks ago. Officers can graduate a recruit by changing
 * their status to "Member" at any time.
 */
function isRecruitInTrial(entry) {
  if (entry.status !== "Recruit") return false;

  // If no last raid date recorded, they haven't raided yet — still in trial.
  if (!entry.lastRaid) return true;

  var lastDate = new Date(entry.lastRaid);
  var cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - (RECRUIT_TRIAL_WEEKS * 7));

  // If their last raid was within the trial window, they're still in trial.
  return lastDate >= cutoff;
}

// ── Menu ────────────────────────────────────────────────────────────────────────

/**
 * Add a custom menu to the spreadsheet for easy access.
 */
function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu("Rolling SR")
    .addItem("Process Weekly SRs", "processWeeklySoftReserves")
    .addItem("Refresh Addon Export", "writeAddonExport")
    .addToUi();
}
