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

/**
 * Strip diacritics and accents (e.g., "Lëgolas" -> "Legolas", "René" -> "Rene").
 */
function stripAccents(str) {
  var s = (str || "").toString();
  if (typeof s.normalize === "function") {
    return s.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
  }
  return s;
}

// ── Aliases & Name Resolution ───────────────────────────────────────────────────

/**
 * Read the Aliases sheet into a lookup map: { [normalizedAlias]: canonicalRosterName }.
 */
function readAliases(ss) {
  ss = ss || SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Aliases");
  var map = {};
  if (!sheet) return map;

  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return map;

  for (var r = 1; r < data.length; r++) {
    var rawAlias = data[r][0];
    var rawTarget = data[r][1];
    var alias = normName(rawAlias);
    var target = normName(rawTarget);
    if (alias && target) {
      map[alias] = target;
    }
  }
  return map;
}

/**
 * Setup or create the Aliases tab with column headers.
 */
function setupAliasesTab() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Aliases");
  if (!sheet) {
    sheet = ss.insertSheet("Aliases");
    sheet.getRange(1, 1, 1, 2).setValues([["Alias_Or_Alt_Name", "Roster_Character_Name"]]);
    sheet.getRange(1, 1, 1, 2).setFontWeight("bold");
    sheet.setColumnWidth(1, 220);
    sheet.setColumnWidth(2, 220);
    SpreadsheetApp.getUi().alert(
      "Aliases Tab Created",
      "Created 'Aliases' tab!\n\nAdd any alt character names, Discord usernames, or common typos in Column A, and map them to the official character name in Column B.",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  } else {
    SpreadsheetApp.getUi().alert(
      "Aliases Tab Exists",
      "'Aliases' tab already exists.\n\nColumn A: Alias_Or_Alt_Name\nColumn B: Roster_Character_Name",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  }
}

/**
 * Resolve a player name from SoftRes against the guild roster and aliases:
 * 1. Direct match on Roster_And_Rolls (case-insensitive via normName).
 * 2. Aliases lookup (alt character or Discord name -> official roster name).
 * 3. Accent/diacritic-insensitive match against Roster and Aliases.
 *
 * @param {string} rawName
 * @param {object} roster
 * @param {object} aliasMap
 * @return {{ resolvedName: string, isGuild: boolean, method: string }}
 */
function resolvePlayerName(rawName, roster, aliasMap) {
  var name = normName(rawName);
  if (!name) {
    return { resolvedName: "", isGuild: false, method: "none" };
  }

  // 1. Direct match on Roster
  if (roster[name]) {
    return { resolvedName: name, isGuild: true, method: "exact" };
  }

  // 2. Direct match in Aliases table
  if (aliasMap && aliasMap[name]) {
    var target = aliasMap[name];
    var inRoster = roster[target] !== undefined;
    return { resolvedName: target, isGuild: inRoster, method: "alias" };
  }

  // 3. Accent-insensitive match against Roster
  var cleanName = stripAccents(name).toLowerCase();
  var rosterNames = Object.keys(roster);
  for (var i = 0; i < rosterNames.length; i++) {
    var rName = rosterNames[i];
    if (stripAccents(rName).toLowerCase() === cleanName) {
      return { resolvedName: rName, isGuild: true, method: "accent" };
    }
  }

  // 4. Accent-insensitive match against Aliases
  if (aliasMap) {
    var aliasKeys = Object.keys(aliasMap);
    for (var j = 0; j < aliasKeys.length; j++) {
      var aKey = aliasKeys[j];
      if (stripAccents(aKey).toLowerCase() === cleanName) {
        var aTarget = aliasMap[aKey];
        var aInRoster = roster[aTarget] !== undefined;
        return { resolvedName: aTarget, isGuild: aInRoster, method: "alias_accent" };
      }
    }
  }

  // Unmatched (Pug or unrecognized typo)
  return { resolvedName: name, isGuild: false, method: "none" };
}

/**
 * Map all incoming SoftRes reservations to canonical roster members.
 */
function mapReservations(rawPlayers, roster, aliasMap) {
  var guildReservations = {};
  var pugsIgnored = [];
  var substitutions = [];

  Object.keys(rawPlayers).forEach(function (rawName) {
    var data = rawPlayers[rawName];
    var res = resolvePlayerName(rawName, roster, aliasMap);

    if (res.isGuild) {
      var canonical = res.resolvedName;
      if (!guildReservations[canonical]) {
        guildReservations[canonical] = {
          items: [],
          class: data.class || "",
        };
      }
      data.items.forEach(function (it) {
        guildReservations[canonical].items.push(it);
      });

      if (res.method !== "exact") {
        substitutions.push({
          original: rawName,
          resolved: canonical,
          method: res.method,
          items: data.items,
        });
      }
    } else {
      pugsIgnored.push({
        name: rawName,
        items: data.items,
      });
    }
  });

  return {
    guildReservations: guildReservations,
    pugsIgnored: pugsIgnored,
    substitutions: substitutions,
  };
}

// ── CSV Parser ──────────────────────────────────────────────────────────────────

/**
 * Parse softres.it CSVs from all tabs starting with "CSV_" (e.g. CSV_Import, CSV_Raid1, CSV_Raid2, etc.).
 * If you have multiple concurrent raids, you can either:
 *   a) Put each raid's softres export into its own tab (e.g. CSV_Raid1, CSV_Raid2, CSV_Raid3, CSV_Raid4).
 *   b) Paste them all one below another into CSV_Import (repeated headers are automatically ignored).
 *
 * Expected columns: Name, Class, ItemId, ItemName, Note, Plus.
 * Returns a map: { playerName: { items: [itemName, ...], class: string } }
 */
function parseSoftresCSV() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheets = ss.getSheets().filter(function (s) {
    return s.getName().toUpperCase().indexOf("CSV") === 0;
  });

  if (sheets.length === 0) {
    throw new Error("No CSV import tabs found (expected tab name starting with 'CSV', e.g. 'CSV_Import' or 'CSV_Raid1').");
  }

  var players = {};
  var totalRowsParsed = 0;

  sheets.forEach(function (sheet) {
    var data = sheet.getDataRange().getValues();
    if (data.length < 2) return; // Empty or header-only tab

    // Detect header columns for this sheet
    var header = data[0].map(function (h) { return h.toString().trim(); });
    var colIdx = {};
    header.forEach(function (h, i) { colIdx[h] = i; });

    var nameCol = colIdx["Name"];
    var itemCol = colIdx["ItemName"] !== undefined ? colIdx["ItemName"] : colIdx["Item Name"];
    var classCol = colIdx["Class"];

    if (nameCol === undefined || itemCol === undefined) {
      // Not a valid softres CSV tab, skip
      return;
    }

    for (var r = 1; r < data.length; r++) {
      var row = data[r];
      var rawName = row[nameCol];
      var rawItem = row[itemCol];

      // Ignore empty rows or repeated headers pasted mid-sheet
      if (!rawName || !rawItem) continue;
      if (rawName.toString().trim().toLowerCase() === "name") continue;

      var pName = normName(rawName);
      var iName = normItem(rawItem);
      if (!pName || !iName) continue;

      if (!players[pName]) {
        players[pName] = {
          items: [],
          class: classCol !== undefined ? row[classCol].toString().trim() : "",
        };
      }
      players[pName].items.push(iName);
      totalRowsParsed++;
    }
  });

  if (totalRowsParsed === 0) {
    throw new Error("CSV tabs were found, but no reservation data rows were detected.");
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
 * Dry Run / Preview:
 * Inspects SoftRes CSV imports against the roster WITHOUT modifying any data.
 * Displays a summary dialog showing:
 *   - Matched guild members & attendance
 *   - Missing members who would accrue a miss (and who would reset)
 *   - Aliases & accent adjustments applied
 *   - Unmatched names (Pugs or typos to review)
 */
function previewWeeklySoftReserves() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  if (!rosterSheet) throw new Error("Roster_And_Rolls tab not found.");

  var rawPlayers = parseSoftresCSV();
  var roster = readRoster(rosterSheet);
  var aliasMap = readAliases(ss);

  var mapping = mapReservations(rawPlayers, roster, aliasMap);
  var guildRes = mapping.guildReservations;
  var pugs = mapping.pugsIgnored;
  var subs = mapping.substitutions;

  var attendingCount = 0;
  var missingMembers = [];
  var willResetMembers = [];

  Object.keys(roster).forEach(function (name) {
    var prev = roster[name];
    if (guildRes[name]) {
      attendingCount++;
    } else {
      if (prev.status !== "Benched") {
        missingMembers.push(name + " (misses: " + (prev.misses + 1) + ")");
        if (prev.misses + 1 >= MISS_THRESHOLD && (prev.rolls1 > 0 || prev.rolls2 > 0)) {
          var details = [];
          if (prev.item1) details.push(prev.item1 + "=" + prev.rolls1);
          if (prev.item2) details.push(prev.item2 + "=" + prev.rolls2);
          willResetMembers.push(name + " [" + details.join(", ") + "]");
        }
      }
    }
  });

  var lines = [];
  lines.push("=== DRY RUN / PREVIEW REPORT ===");
  lines.push("");
  lines.push("✓ Guild Members Present: " + attendingCount + " / " + Object.keys(roster).length);

  if (subs.length > 0) {
    lines.push("");
    lines.push("🔄 Resolved Aliases / Accents (" + subs.length + "):");
    subs.forEach(function (s) {
      lines.push("  • " + s.original + " → " + s.resolved + " (" + s.method + ")");
    });
  }

  if (pugs.length > 0) {
    lines.push("");
    lines.push("⚠️ Unmatched Names (Pugs or typos) (" + pugs.length + "):");
    pugs.forEach(function (p) {
      lines.push("  • " + p.name + (p.items.length > 0 ? " [SR: " + p.items.join(", ") + "]" : ""));
    });
    lines.push("  (If any of these are guild members, add them to the 'Aliases' tab before committing!)");
  } else {
    lines.push("");
    lines.push("ℹ️ No unmatched / pug names found.");
  }

  if (missingMembers.length > 0) {
    lines.push("");
    lines.push("❌ Absent Guild Members (" + missingMembers.length + "):");
    lines.push("  " + missingMembers.join(", "));
  }

  if (willResetMembers.length > 0) {
    lines.push("");
    lines.push("🚨 Extra Rolls RESETTING this week due to 2 consecutive misses:");
    willResetMembers.forEach(function (m) {
      lines.push("  • " + m);
    });
  }

  lines.push("");
  lines.push("NOTE: No changes have been saved to your spreadsheet.");

  var ui = SpreadsheetApp.getUi();
  ui.alert("Rolling SR — Preview & Review", lines.join("\n"), ui.ButtonSet.OK);
}

/**
 * Main entry point. Call from the Apps Script editor or attach to a menu/button.
 *
 * Steps:
 *   1. Parse CSV_Import.
 *   2. Map names via Aliases & accent stripping.
 *   3. If unmatched names found, prompt officer for review.
 *   4. Update Roster_And_Rolls (increment / reset extra rolls, track misses).
 *   5. Write the Gargul addon string to Addon_Export!A1.
 */
function processWeeklySoftReserves() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  if (!rosterSheet) throw new Error("Roster_And_Rolls tab not found.");

  var today = todayStamp();

  // ── 1. Parse this week's reserves ──
  var rawPlayers = parseSoftresCSV(); // { rawPlayerName: { items:[], class } }
  var aliasMap = readAliases(ss);
  var roster = readRoster(rosterSheet);

  // ── 2. Map reservations to canonical roster members ──
  var mapping = mapReservations(rawPlayers, roster, aliasMap);
  var thisWeek = mapping.guildReservations;
  var pugsIgnored = mapping.pugsIgnored.map(function (p) { return p.name; });
  var substitutions = mapping.substitutions;

  // ── 3. Prompt if unmatched names detected (Option 3 protection) ──
  if (pugsIgnored.length > 0) {
    try {
      var ui = SpreadsheetApp.getUi();
      var previewPugs = pugsIgnored.slice(0, 10).join(", ") + (pugsIgnored.length > 10 ? "..." : "");
      var resp = ui.alert(
        "Unmatched Names Found (" + pugsIgnored.length + ")",
        "The following SoftRes name(s) are NOT on your guild roster or aliases tab:\n\n" +
          previewPugs +
          "\n\n• Click YES if these are external Pugs and you want to commit.\n" +
          "• Click NO to cancel so you can add any guild typos to the 'Aliases' tab first.",
        ui.ButtonSet.YES_NO
      );
      if (resp !== ui.Button.YES) {
        ss.toast("Update cancelled by user.", "Rolling SR", 5);
        return;
      }
    } catch (e) {
      // Running headless or non-interactively — proceed
    }
  }

  // ── 4. Create automatic pre-update backup snapshot ──
  createRosterSnapshot(true);

  // ── 5. Process ONLY players on the guild roster ──
  Object.keys(roster).forEach(function (name) {
    var prev = roster[name];
    var curr = thisWeek[name] || null;

    // Normalise incoming items to exactly MAX_SR slots.
    var newItems = curr ? curr.items.slice(0, MAX_SR) : [];
    while (newItems.length < MAX_SR) newItems.push("");
    var newItem1 = newItems[0];
    var newItem2 = newItems[1];

    var status = prev.status || "Member";

    // ── Attendance / miss tracking ──
    if (curr) {
      // Player participated this week (present in CSV or mapped via alias).
      var misses = 0; // reset consecutive misses on attendance
      var lastRaid = today;

      // ── Extra-roll calculation per slot ──
      var rolls1 = calcExtraRolls(prev, 1, newItem1, status);
      var rolls2 = calcExtraRolls(prev, 2, newItem2, status);

      writePlayerRow(rosterSheet, prev.row, name, status, newItem1, rolls1, newItem2, rolls2, misses, lastRaid);
    } else {
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

  // ── 5. Build and write the addon export string ──
  writeAddonExport(ss);

  // ── 6. Toast summary ──
  var msg = "Updated " + Object.keys(roster).length + " guild members.";
  if (substitutions.length > 0) {
    msg += " (" + substitutions.length + " alias/accent matches).";
  }
  if (pugsIgnored.length > 0) {
    msg += " Ignored " + pugsIgnored.length + " pug(s).";
  }
  ss.toast(msg, "Rolling SR", 10);
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

  var targetLower = item.toLowerCase();
  if (entry.item1 && entry.item1.toLowerCase() === targetLower) {
    sheet.getRange(entry.row, COL.ITEM1 + 1, 1, 2).setValues([["", 0]]);
  }
  if (entry.item2 && entry.item2.toLowerCase() === targetLower) {
    sheet.getRange(entry.row, COL.ITEM2 + 1, 1, 2).setValues([["", 0]]);
  }
}

/**
 * Interactive dialog to mark an item won by a player and reset their extra rolls.
 */
function markItemWonDialog() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var roster = readRoster(sheet);
  var aliasMap = readAliases(ss);

  var resp = ui.prompt(
    "🏆 Mark Item Won",
    "Enter the character name who won an item:",
    ui.ButtonSet.OK_CANCEL
  );
  if (resp.getSelectedButton() !== ui.Button.OK) return;

  var rawName = resp.getResponseText().trim();
  if (!rawName) return;

  var res = resolvePlayerName(rawName, roster, aliasMap);
  var canonical = res.resolvedName;
  var entry = roster[canonical];

  if (!entry) {
    ui.alert("Player Not Found", "Could not find '" + rawName + "' on Roster_And_Rolls.", ui.ButtonSet.OK);
    return;
  }

  var options = [];
  if (entry.item1) options.push("1: " + entry.item1 + " (" + entry.rolls1 + " extra rolls)");
  if (entry.item2) options.push("2: " + entry.item2 + " (" + entry.rolls2 + " extra rolls)");

  if (options.length === 0) {
    ui.alert("No Items", canonical + " currently has no active reserved items on the roster.", ui.ButtonSet.OK);
    return;
  }

  var itemToReset = "";
  if (options.length === 1) {
    itemToReset = entry.item1 || entry.item2;
    var confirm = ui.alert(
      "Confirm Item Won",
      "Mark '" + itemToReset + "' as won by " + canonical + "?\n\nExtra rolls on this item will reset to 0.",
      ui.ButtonSet.YES_NO
    );
    if (confirm !== ui.Button.YES) return;
  } else {
    var itemResp = ui.prompt(
      "Select Item Won",
      canonical + " has 2 reserved items:\n\n" +
        options.join("\n") +
        "\n\nEnter 1 for Slot 1, 2 for Slot 2, or type the item name:",
      ui.ButtonSet.OK_CANCEL
    );
    if (itemResp.getSelectedButton() !== ui.Button.OK) return;
    var val = itemResp.getResponseText().trim();
    if (val === "1") {
      itemToReset = entry.item1;
    } else if (val === "2") {
      itemToReset = entry.item2;
    } else {
      itemToReset = normItem(val);
    }
  }

  markItemWon(canonical, itemToReset);
  writeAddonExport(ss);

  ui.alert("Item Won Recorded", "Reset extra rolls for '" + itemToReset + "' on " + canonical + " to 0.\n\nAddon export refreshed.", ui.ButtonSet.OK);
}

// ── Officer Tools ───────────────────────────────────────────────────────────────

/**
 * Excuse an absence (vacation, prior notice) for a player to protect their streak.
 */
function excuseAbsenceDialog() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var roster = readRoster(sheet);
  var aliasMap = readAliases(ss);

  var resp = ui.prompt(
    "🌴 Excuse Absence / Vacation",
    "Enter the character name whose absence is excused:",
    ui.ButtonSet.OK_CANCEL
  );
  if (resp.getSelectedButton() !== ui.Button.OK) return;

  var rawName = resp.getResponseText().trim();
  if (!rawName) return;

  var res = resolvePlayerName(rawName, roster, aliasMap);
  var canonical = res.resolvedName;
  var entry = roster[canonical];

  if (!entry) {
    ui.alert("Player Not Found", "Could not find '" + rawName + "' on Roster_And_Rolls.", ui.ButtonSet.OK);
    return;
  }

  // Reset misses to 0
  sheet.getRange(entry.row, COL.MISSES + 1, 1, 1).setValue(0);
  ss.toast("Absence excused for " + canonical + ". Consecutive misses reset to 0.", "Rolling SR", 5);
}

/**
 * Scan for recruits who have passed the trial duration and offer 1-click promotion to Member.
 */
function checkRecruitGraduation() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var roster = readRoster(sheet);

  var eligible = [];
  Object.keys(roster).forEach(function (name) {
    var entry = roster[name];
    if (entry.status === "Recruit" && !isRecruitInTrial(entry)) {
      eligible.push({ name: name, row: entry.row, lastRaid: entry.lastRaid });
    }
  });

  if (eligible.length === 0) {
    ui.alert("Recruits Up to Date", "No recruits are currently eligible for graduation (trial period is " + RECRUIT_TRIAL_WEEKS + " weeks).", ui.ButtonSet.OK);
    return;
  }

  var namesList = eligible.map(function (e) { return "• " + e.name + " (first recorded raid: " + e.lastRaid + ")"; }).join("\n");
  var resp = ui.alert(
    "🎓 Graduate Recruits (" + eligible.length + ")",
    "The following recruit(s) have completed their " + RECRUIT_TRIAL_WEEKS + "-week trial:\n\n" +
      namesList +
      "\n\nWould you like to promote them to 'Member' now?\n(This enables their extra rolls in the in-game addon export).",
    ui.ButtonSet.YES_NO
  );

  if (resp === ui.Button.YES) {
    eligible.forEach(function (e) {
      sheet.getRange(e.row, COL.STATUS + 1, 1, 1).setValue("Member");
    });
    writeAddonExport(ss);
    ui.alert("Graduation Complete", "Successfully promoted " + eligible.length + " recruit(s) to Member and updated Addon Export!", ui.ButtonSet.OK);
  }
}

/**
 * Create a timestamped backup snapshot of Roster_And_Rolls.
 * @param {boolean} [silent=false]
 */
function createRosterSnapshot(silent) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  if (!rosterSheet) throw new Error("Roster_And_Rolls tab not found.");

  var today = todayStamp();
  var baseName = "Archive_" + today;
  var sheetName = baseName;
  var counter = 1;
  while (ss.getSheetByName(sheetName)) {
    counter++;
    sheetName = baseName + "_" + counter;
  }

  var newSheet = rosterSheet.copyTo(ss);
  newSheet.setName(sheetName);

  if (!silent) {
    SpreadsheetApp.getUi().alert(
      "Backup Created",
      "Created backup snapshot tab: '" + sheetName + "'.",
      SpreadsheetApp.getUi().ButtonSet.OK
    );
  } else {
    ss.toast("Auto-backup created: " + sheetName, "Rolling SR", 3);
  }
}

/**
 * Display a summary dashboard of active streaks, at-risk members, and status counts.
 */
function showLeaderboardAndStats() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var roster = readRoster(sheet);

  var streaks = [];
  var atRisk = [];
  var statusCounts = { Member: 0, Recruit: 0, Alt: 0, Benched: 0, Other: 0 };

  Object.keys(roster).forEach(function (name) {
    var e = roster[name];
    var stat = e.status || "Member";
    if (statusCounts[stat] !== undefined) {
      statusCounts[stat]++;
    } else {
      statusCounts.Other++;
    }

    if (e.rolls1 > 0 && e.item1) {
      streaks.push({ player: name, item: e.item1, rolls: e.rolls1 });
    }
    if (e.rolls2 > 0 && e.item2) {
      streaks.push({ player: name, item: e.item2, rolls: e.rolls2 });
    }

    if (e.misses === 1 && (e.rolls1 > 0 || e.rolls2 > 0)) {
      var details = [];
      if (e.item1 && e.rolls1 > 0) details.push(e.item1 + " (+" + e.rolls1 + ")");
      if (e.item2 && e.rolls2 > 0) details.push(e.item2 + " (+" + e.rolls2 + ")");
      atRisk.push("• " + name + ": " + details.join(", "));
    }
  });

  streaks.sort(function (a, b) { return b.rolls - a.rolls; });

  var lines = [];
  lines.push("=== ROLLING SR DASHBOARD ===");
  lines.push("");
  lines.push("👥 Roster Breakdown:");
  lines.push("  Members: " + statusCounts.Member + " | Recruits: " + statusCounts.Recruit + " | Alts: " + statusCounts.Alt + " | Benched: " + statusCounts.Benched);

  lines.push("");
  lines.push("🔥 Top Active Roll Streaks:");
  if (streaks.length > 0) {
    streaks.slice(0, 5).forEach(function (s, idx) {
      lines.push("  " + (idx + 1) + ". " + s.player + " — " + s.item + " (+" + s.rolls + " bonus rolls)");
    });
  } else {
    lines.push("  (No extra rolls accumulated yet)");
  }

  lines.push("");
  lines.push("⚠️ At-Risk Streaks (1 Miss — Will Reset if Absent Next Raid):");
  if (atRisk.length > 0) {
    atRisk.slice(0, 8).forEach(function (m) {
      lines.push("  " + m);
    });
  } else {
    lines.push("  ✓ No raiders currently at risk of streak resets.");
  }

  ui.alert("Rolling SR — Analytics & Streaks", lines.join("\n"), ui.ButtonSet.OK);
}

/**
 * Sanitize, clean whitespace, Title Case player names, and sort roster alphabetically.
 */
function formatAndCleanRoster() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  if (!sheet) throw new Error("Roster_And_Rolls tab not found.");

  var data = sheet.getDataRange().getValues();
  if (data.length < 2) {
    ui.alert("Empty Roster", "Roster_And_Rolls has no member rows to clean.", ui.ButtonSet.OK);
    return;
  }

  var header = data[0];
  var rows = [];

  for (var r = 1; r < data.length; r++) {
    var row = data[r];
    var rawName = row[COL.PLAYER];
    if (!rawName || !rawName.toString().trim()) continue;

    var name = normName(rawName);
    var status = (row[COL.STATUS] || "Member").toString().trim();
    var item1 = normItem(row[COL.ITEM1]);
    var rolls1 = parseInt(row[COL.ROLLS1], 10) || 0;
    var item2 = normItem(row[COL.ITEM2]);
    var rolls2 = parseInt(row[COL.ROLLS2], 10) || 0;
    var misses = parseInt(row[COL.MISSES], 10) || 0;
    var lastRaid = (row[COL.LAST_RAID] || "").toString().trim();

    rows.push([name, status, item1, rolls1, item2, rolls2, misses, lastRaid]);
  }

  // Sort alphabetically by player name
  rows.sort(function (a, b) {
    return a[0].localeCompare(b[0]);
  });

  // Clear existing content and rewrite
  sheet.clearContents();
  sheet.getRange(1, 1, 1, ROSTER_COLS).setValues([header]);
  sheet.getRange(1, 1, 1, ROSTER_COLS).setFontWeight("bold");

  if (rows.length > 0) {
    sheet.getRange(2, 1, rows.length, ROSTER_COLS).setValues(rows);
  }

  ui.alert("Roster Cleaned", "Cleaned, sanitized, and sorted " + rows.length + " player rows alphabetically.", ui.ButtonSet.OK);
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
    .addItem("🔍 Preview & Review (Dry Run)", "previewWeeklySoftReserves")
    .addItem("⚡ Process Weekly SRs (Commit)", "processWeeklySoftReserves")
    .addSeparator()
    .addItem("🏆 Mark Item Won", "markItemWonDialog")
    .addItem("🌴 Excuse Absence / Vacation", "excuseAbsenceDialog")
    .addItem("🎓 Check Recruit Graduation", "checkRecruitGraduation")
    .addItem("📊 Streak Leaderboard & Stats", "showLeaderboardAndStats")
    .addSeparator()
    .addItem("📦 Create Backup Snapshot", "createRosterSnapshot")
    .addItem("🧹 Clean & Sort Roster", "formatAndCleanRoster")
    .addItem("📋 Setup Aliases Tab", "setupAliasesTab")
    .addItem("🔄 Refresh Addon Export", "writeAddonExport")
    .addToUi();
}
