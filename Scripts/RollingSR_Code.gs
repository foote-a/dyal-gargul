/**
 * Soft Reserve+ — Google Apps Script for tracking per-item soft-reserve extra rolls.
 *
 * Sheet tabs:
 *   Roster_And_Rolls  — Master guild roster with accumulated extra rolls (never Pugs).
 *   CSV_Import        — Officers paste raw softres.it CSV here (also supports CSV_Raid1..4).
 *   Addon_Export      — Cell A1 holds the plain-text import string for Gargul.
 *   Aliases           — Maps alt characters, nicknames, or typos to Roster_Character_Name.
 *
 * Use the custom "Soft Reserve+" menu in Google Sheets to preview, commit, manage streaks,
 * initialize tabs, or generate the Gargul addon export string.
 */

// ── Config ──────────────────────────────────────────────────────────────────────

/** Maximum soft reserves per player per week. */
var MAX_SR = 2;

/** Consecutive misses that reset all extra rolls to 0. */
var MISS_THRESHOLD = 2;

/** Weeks a recruit must attend before extra rolls can be spent. */
var RECRUIT_TRIAL_WEEKS = 2;

/** Maximum accumulated extra rolls per item slot (configurable cap). */
var MAX_EXTRA_ROLLS = 100;

/** Whether Alt characters accumulate stacking extra rolls (default: false). */
var ALTS_ACCRUE_ROLLS = false;

// ── Column indices (0-based) in Roster_And_Rolls ────────────────────────────────

var COL = {
  PLAYER:    0,  // A – PlayerName
  STATUS:    1,  // B – Member | Recruit | Alt | Benched
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

/**
 * Check whether a status string represents an Alt (e.g., "Alt", "Alt (Dyal)", "Alt: Dyal").
 */
function isAltStatus(status) {
  var s = (status || "").toString().trim().toLowerCase();
  return s === "alt" || s.indexOf("alt ") === 0 || s.indexOf("alt(") === 0 || s.indexOf("alt:") === 0;
}

/**
 * Extract a linked Main name if encoded in Status (e.g., "Alt (Dyal)" or "Alt: Dyal").
 */
function extractMainFromStatus(status) {
  var s = (status || "").toString().trim();
  if (!isAltStatus(s)) return "";
  var openIdx = s.indexOf("(");
  var closeIdx = s.indexOf(")");
  if (openIdx !== -1 && closeIdx > openIdx + 1) {
    return normName(s.slice(openIdx + 1, closeIdx));
  }
  var colonIdx = s.indexOf(":");
  if (colonIdx !== -1 && colonIdx + 1 < s.length) {
    return normName(s.slice(colonIdx + 1));
  }
  return "";
}

/**
 * Find the Main character linked to an Alt via Status ("Alt (Main)") or the Aliases tab.
 */
function getLinkedMain(altName, roster, aliasMap) {
  var normAlt = normName(altName);
  if (roster && roster[normAlt]) {
    var fromStatus = extractMainFromStatus(roster[normAlt].status);
    if (fromStatus && roster[fromStatus]) {
      return fromStatus;
    }
  }
  if (aliasMap && aliasMap[normAlt] && roster && roster[aliasMap[normAlt]]) {
    return aliasMap[normAlt];
  }
  return "";
}

// ── Aliases & Name Resolution ───────────────────────────────────────────────────

/**
 * Read the Aliases sheet into a lookup map: { [normalizedAlias]: canonicalRosterName }.
 * Also attaches _altTypes: { [normalizedAlias]: true } when optional Column C is "Alt".
 */
function readAliases(ss) {
  ss = ss || SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Aliases");
  var map = {};
  Object.defineProperty(map, "_altTypes", { value: {}, enumerable: false, writable: true });
  if (!sheet) return map;

  var data = sheet.getDataRange().getValues();
  if (data.length < 2) return map;

  for (var r = 1; r < data.length; r++) {
    var rawAlias = data[r][0];
    var rawTarget = data[r][1];
    var rawType = (data[r][2] || "").toString().trim().toLowerCase();
    var alias = normName(rawAlias);
    var target = normName(rawTarget);
    if (alias && target) {
      map[alias] = target;
      if (rawType === "alt") {
        map._altTypes[alias] = true;
      }
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
  var created = false;
  if (!sheet) {
    sheet = ss.insertSheet("Aliases");
    created = true;
  }
  sheet.getRange(1, 1, 1, 3).setValues([["Alias_Or_Alt_Name", "Roster_Character_Name", "Type"]]).setFontWeight("bold");
  sheet.setFrozenRows(1);
  sheet.setColumnWidth(1, 220);
  sheet.setColumnWidth(2, 220);
  sheet.setColumnWidth(3, 140);

  var typeRule = SpreadsheetApp.newDataValidation()
    .requireValueInList(["Alt", "Alias"], true)
    .setAllowInvalid(true)
    .build();
  sheet.getRange(2, 3, 300, 1).setDataValidation(typeRule);

  SpreadsheetApp.getUi().alert(
    created ? "Aliases Tab Created" : "Aliases Tab Updated",
    (created ? "Created 'Aliases' tab!\n\n" : "Updated 'Aliases' tab headers and dropdowns!\n\n") +
      "• Column A: Alias_Or_Alt_Name (Alt character, nickname, or typo)\n" +
      "• Column B: Roster_Character_Name (Main character on Roster_And_Rolls)\n" +
      "• Column C: Type ('Alt' to link an Alt to a Main, or 'Alias' for name typos)",
    SpreadsheetApp.getUi().ButtonSet.OK
  );
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
 * Map all incoming SoftRes reservations to canonical roster members,
 * and track which Mains had an Alt attend so their Main's rolls are protected.
 */
function mapReservations(rawPlayers, roster, aliasMap) {
  var guildReservations = {};
  var pugsIgnored = [];
  var substitutions = [];
  var altProtectedMains = {}; // { [mainName]: altName }

  Object.keys(rawPlayers).forEach(function (rawName) {
    var data = rawPlayers[rawName];
    var normRaw = normName(rawName);

    // Check if rawName is an explicit Alt in Aliases (Column C = "Alt") without a roster row yet
    if (!roster[normRaw] && aliasMap && aliasMap._altTypes && aliasMap._altTypes[normRaw] && aliasMap[normRaw] && roster[aliasMap[normRaw]]) {
      var mainTarget = aliasMap[normRaw];
      altProtectedMains[mainTarget] = normRaw;
      substitutions.push({
        original: rawName,
        resolved: mainTarget + " (protected via Alt " + normRaw + ")",
        method: "alt_link",
        items: data.items,
      });
      return;
    }

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

      // If this character is an Alt on Roster_And_Rolls, also protect their linked Main
      if (roster[canonical] && isAltStatus(roster[canonical].status)) {
        var linkedMain = getLinkedMain(canonical, roster, aliasMap);
        if (linkedMain && linkedMain !== canonical) {
          altProtectedMains[linkedMain] = canonical;
        }
      }

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
    altProtectedMains: altProtectedMains,
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
  var altProtected = mapping.altProtectedMains || {};

  var attendingCount = 0;
  var protectedMainsList = [];
  var missingMembers = [];
  var willResetMembers = [];

  Object.keys(roster).forEach(function (name) {
    var prev = roster[name];
    if (guildRes[name]) {
      attendingCount++;
    } else if (altProtected[name]) {
      protectedMainsList.push(name + " (played on Alt: " + altProtected[name] + ")");
    } else if (!isAltStatus(prev.status)) {
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
  lines.push("✓ Guild Characters Present: " + attendingCount + " / " + Object.keys(roster).length);

  if (protectedMainsList.length > 0) {
    lines.push("");
    lines.push("🛡️ Mains Protected by Alt Attendance (" + protectedMainsList.length + "):");
    protectedMainsList.forEach(function (m) {
      lines.push("  • " + m + " — Main rolls preserved, 0 misses");
    });
  }

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
  ui.alert("Soft Reserve+ — Preview & Review", lines.join("\n"), ui.ButtonSet.OK);
}

/**
 * Main entry point. Call from the Apps Script editor or attach to a menu/button.
 *
 * Steps:
 *   1. Parse CSV_Import.
 *   2. Map names via Aliases & accent stripping (and detect Alt -> Main protection).
 *   3. If unmatched names found, prompt officer for review.
 *   4. Update Roster_And_Rolls (increment / reset extra rolls, track misses).
 *   5. Auto-apply any won-items string in Addon_Export!A3.
 *   6. Write the Gargul addon string to Addon_Export!A1.
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
  var altProtectedMains = mapping.altProtectedMains || {};

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
        ss.toast("Update cancelled by user.", "Soft Reserve+", 5);
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
    } else if (altProtectedMains[name]) {
      // Player played on their Alt this week: Main's items & rolls stay untouched, misses = 0
      writePlayerRow(rosterSheet, prev.row, name, status,
        prev.item1, prev.rolls1, prev.item2, prev.rolls2, 0, today);
    } else if (isAltStatus(status) && !ALTS_ACCRUE_ROLLS) {
      // Unattended Alt row when ALTS_ACCRUE_ROLLS is false: Alts always have 0 extra rolls
      writePlayerRow(rosterSheet, prev.row, name, status,
        prev.item1, 0, prev.item2, 0, 0, prev.lastRaid);
    } else {
      // Player NOT in this week's CSV.
      var newMisses = prev.misses + 1;

      // If benched (officer marks status as "Benched"), treat as attending.
      if (prev.status === "Benched") {
        // Benched players keep their items, gain +1 roll each (capped at MAX_EXTRA_ROLLS), and don't accumulate misses.
        var benchRolls1 = prev.item1 ? Math.min(prev.rolls1 + 1, MAX_EXTRA_ROLLS) : 0;
        var benchRolls2 = prev.item2 ? Math.min(prev.rolls2 + 1, MAX_EXTRA_ROLLS) : 0;
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

  // ── 6. Auto-apply any pending /rsr won string pasted in Addon_Export!A3 ──
  var exportSheet = ss.getSheetByName("Addon_Export");
  var wonAppliedCount = 0;
  if (exportSheet) {
    var pendingWon = (exportSheet.getRange("A3").getValue() || "").toString().trim();
    if (pendingWon) {
      var applied = applyWonItemsString(pendingWon, ss);
      wonAppliedCount = applied.length;
      exportSheet.getRange("A3").clearContent();
    }
  }

  // ── 7. Build and write the addon export string ──
  writeAddonExport(ss);

  // ── 8. Toast summary ──
  var msg = "Updated " + Object.keys(roster).length + " guild members.";
  if (Object.keys(altProtectedMains).length > 0) {
    msg += " (" + Object.keys(altProtectedMains).length + " main(s) protected via Alt).";
  }
  if (wonAppliedCount > 0) {
    msg += " Applied " + wonAppliedCount + " won item reset(s).";
  }
  if (pugsIgnored.length > 0) {
    msg += " Ignored " + pugsIgnored.length + " pug(s).";
  }
  ss.toast(msg, "Soft Reserve+", 10);
}

/**
 * Calculate extra rolls for a single item slot.
 * Alts accumulate 0 rolls unless ALTS_ACCRUE_ROLLS is enabled.
 * Mains (and Alts when ALTS_ACCRUE_ROLLS is true) accumulate +1 when reserving the same item again, capped at MAX_EXTRA_ROLLS (100).
 *
 * @param {object|null} prev  Previous roster entry (null if new player).
 * @param {number}      slot  1 or 2.
 * @param {string}      newItem  The item name reserved this week (may be "").
 * @param {string}      status  Player's status (Member, Recruit, Alt, Benched).
 * @return {number}     Extra rolls to store.
 */
function calcExtraRolls(prev, slot, newItem, status) {
  if (!newItem) return 0; // No reservation → no extra rolls.
  if (isAltStatus(status) && !ALTS_ACCRUE_ROLLS) return 0; // Alts only accrue rolls when ALTS_ACCRUE_ROLLS is enabled.

  var prevItem  = prev ? (slot === 1 ? prev.item1  : prev.item2)  : "";
  var prevRolls = prev ? (slot === 1 ? prev.rolls1 : prev.rolls2) : 0;

  // Check if misses were high enough to have already reset rolls.
  if (prev && prev.misses >= MISS_THRESHOLD) {
    prevRolls = 0;
  }

  if (prevItem === newItem) {
    // Same item reserved again — accumulate up to MAX_EXTRA_ROLLS.
    return Math.min(prevRolls + 1, MAX_EXTRA_ROLLS);
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
 * @return {boolean}           True if a matching item slot was found and reset.
 */
function markItemWon(playerName, itemName) {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  var roster = readRoster(sheet);

  var name = normName(playerName);
  var item = normItem(itemName);
  var entry = roster[name];
  if (!entry) return false;

  var reset = false;
  var targetLower = item.toLowerCase();
  if (entry.item1 && entry.item1.toLowerCase() === targetLower) {
    sheet.getRange(entry.row, COL.ITEM1 + 1, 1, 2).setValues([["", 0]]);
    reset = true;
  }
  if (entry.item2 && entry.item2.toLowerCase() === targetLower) {
    sheet.getRange(entry.row, COL.ITEM2 + 1, 1, 2).setValues([["", 0]]);
    reset = true;
  }
  return reset;
}

/**
 * Parse and apply an in-game won-items export string from `/rsr won`
 * Format: "Player1:Item1;Player2:Item2;"
 *
 * @param {string} wonString
 * @param {Spreadsheet} [ss]
 * @return {Array<{player: string, item: string, matched: boolean}>}
 */
function applyWonItemsString(wonString, ss) {
  ss = ss || SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  if (!sheet) throw new Error("Roster_And_Rolls tab not found.");

  var roster = readRoster(sheet);
  var aliasMap = readAliases(ss);
  var results = [];

  var clean = (wonString || "").toString().trim();
  clean = clean.replace(/^\/?(?:gl\s+)?(?:rsr|srp|srplus|softreserveplus)\s+won\s*/i, "").trim();
  if (!clean) return results;

  var entries = clean.split(";");
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i].trim();
    if (!entry) continue;

    var colonIdx = entry.indexOf(":");
    if (colonIdx < 1) continue;

    var rawPlayer = entry.slice(0, colonIdx).trim();
    var rawItemsPart = entry.slice(colonIdx + 1).trim();
    if (!rawPlayer || !rawItemsPart) continue;

    var res = resolvePlayerName(rawPlayer, roster, aliasMap);
    var canonical = res.resolvedName || normName(rawPlayer);

    var itemNames = rawItemsPart.split(",");
    for (var j = 0; j < itemNames.length; j++) {
      var cleanItem = normItem(itemNames[j].replace(/=\s*\d+$/, ""));
      if (!cleanItem) continue;
      var matched = markItemWon(canonical, cleanItem);
      results.push({ player: canonical, item: cleanItem, matched: matched });
    }
  }

  return results;
}

/**
 * Interactive dialog to paste the `/rsr won` string from Gargul and automatically reset all won items.
 */
function importWonItemsDialog() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();

  var resp = ui.prompt(
    "📥 Import Won Items String (From /srp won or /rsr won)",
    "Run '/srp won' (or '/rsr won') in-game after your raid and paste the exported string below\n(Format: Player1:Item1;Player2:Item2;):",
    ui.ButtonSet.OK_CANCEL
  );
  if (resp.getSelectedButton() !== ui.Button.OK) return;

  var raw = resp.getResponseText().trim();
  if (!raw) return;

  var results = applyWonItemsString(raw, ss);
  writeAddonExport(ss);

  if (results.length === 0) {
    ui.alert("Invalid Format", "No valid 'Player:Item;' entries were found in the pasted string.", ui.ButtonSet.OK);
    return;
  }

  var lines = ["Processed " + results.length + " won item entry/entries:"];
  lines.push("");
  results.forEach(function (r) {
    if (r.matched) {
      lines.push("✓ " + r.player + " — '" + r.item + "' cleared & reset to 0");
    } else {
      lines.push("ℹ️ " + r.player + " — '" + r.item + "' (no active slot matched)");
    }
  });
  lines.push("");
  lines.push("Addon_Export!A1 has been refreshed.");

  ui.alert("🏆 Won Items Imported", lines.join("\n"), ui.ButtonSet.OK);
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
  ss.toast("Absence excused for " + canonical + ". Consecutive misses reset to 0.", "Soft Reserve+", 5);
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
      eligible.push({ name: name, row: entry.row, rolls1: entry.rolls1, rolls2: entry.rolls2, lastRaid: entry.lastRaid });
    }
  });

  if (eligible.length === 0) {
    ui.alert("Recruits Up to Date", "No recruits are currently eligible for graduation (trial period is " + RECRUIT_TRIAL_WEEKS + " weeks).", ui.ButtonSet.OK);
    return;
  }

  var namesList = eligible.map(function (e) {
    var weeks = Math.max(e.rolls1 || 0, e.rolls2 || 0);
    return "• " + e.name + " (" + weeks + "+ week(s) attended / active since: " + e.lastRaid + ")";
  }).join("\n");
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
    ss.toast("Auto-backup created: " + sheetName, "Soft Reserve+", 3);
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
  lines.push("=== SOFT RESERVE+ DASHBOARD ===");
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

  ui.alert("Soft Reserve+ — Analytics & Streaks", lines.join("\n"), ui.ButtonSet.OK);
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
 * Format: PlayerName:Item1=Rolls,Item2=Rolls;AltName*alt:Item1=0;
 *
 * Recruits still in their trial period have their available extra rolls
 * exported as 0 (they accumulate internally but can't spend them yet).
 * Alts are exported with the "*alt" suffix and 0 extra rolls.
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

    // The addon treats everyone in this string as guild, so Pugs are left out.
    if (e.status === "Pug") return;

    var isAlt = isAltStatus(e.status);

    var recruitInTrial = isRecruitInTrial(e);

    // Skip non-alt, non-recruit players with no active reservations.
    // Alts and Recruits in trial are always exported (even with empty items) so Gargul recognizes their status in Phase 1.
    if (!isAlt && !recruitInTrial && !e.item1 && !e.item2) return;

    var items = [];
    if (e.item1) {
      var r1 = ((isAlt && !ALTS_ACCRUE_ROLLS) || recruitInTrial) ? 0 : Math.min(e.rolls1, MAX_EXTRA_ROLLS);
      items.push(e.item1 + "=" + r1);
    }
    if (e.item2) {
      var r2 = ((isAlt && !ALTS_ACCRUE_ROLLS) || recruitInTrial) ? 0 : Math.min(e.rolls2, MAX_EXTRA_ROLLS);
      items.push(e.item2 + "=" + r2);
    }

    var tag = isAlt ? "*alt" : (recruitInTrial ? "*recruit" : "");
    if (items.length > 0 || isAlt || recruitInTrial) {
      parts.push(name + tag + ":" + items.join(","));
    }
  });

  var output = parts.join(";");
  if (output) output += ";";

  exportSheet.getRange("A1").clearFormat();
  exportSheet.getRange("A1").setValue(output);
  return output;
}

/**
 * Show the generated Addon_Export string in a dialog for instant copying.
 */
function showExportStringDialog() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var output = writeAddonExport(ss);
  var ui = SpreadsheetApp.getUi();

  if (!output) {
    ui.alert("Addon Export Empty", "No active guild reservations found on Roster_And_Rolls yet.", ui.ButtonSet.OK);
    return;
  }

  ui.alert(
    "📋 Copy Addon Export String",
    "Copy the string below (or from Addon_Export!A1) and run in-game:\n\n/srp " + output + "\n(or /rsr " + output + ")",
    ui.ButtonSet.OK
  );
}

/**
 * Generate a ready-to-paste Discord summary of active bonus roll streaks.
 */
function generateDiscordSummary() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = ss.getSheetByName("Roster_And_Rolls");
  if (!sheet) throw new Error("Roster_And_Rolls tab not found.");

  var roster = readRoster(sheet);
  var lines = [];
  lines.push("**🎲 Soft Reserve+ — Weekly Bonus Rolls Summary (" + todayStamp() + ")**");
  lines.push("```");

  var names = Object.keys(roster).sort();
  var activeCount = 0;

  names.forEach(function (name) {
    var e = roster[name];
    if (!e.item1 && !e.item2) return;
    if (e.status === "Pug") return;

    var isAlt = isAltStatus(e.status);
    var inTrial = isRecruitInTrial(e);
    var items = [];
    if (e.item1) {
      var r1 = (isAlt && !ALTS_ACCRUE_ROLLS) ? "0 [Alt]" : (inTrial ? "0 [Trial]" : "+" + Math.min(e.rolls1, MAX_EXTRA_ROLLS));
      items.push(e.item1 + " (" + r1 + ")");
    }
    if (e.item2) {
      var r2 = (isAlt && !ALTS_ACCRUE_ROLLS) ? "0 [Alt]" : (inTrial ? "0 [Trial]" : "+" + Math.min(e.rolls2, MAX_EXTRA_ROLLS));
      items.push(e.item2 + " (" + r2 + ")");
    }
    var roleTag = isAlt ? " [Alt]" : "";
    var missTag = ((!isAlt || ALTS_ACCRUE_ROLLS) && e.misses === 1) ? " ⚠️ [1 Miss]" : "";
    lines.push(name + roleTag + ": " + items.join(", ") + missTag);
    activeCount++;
  });

  if (activeCount === 0) {
    lines.push("No active soft reserves recorded yet.");
  }
  lines.push("```");

  ui.alert("📢 Discord Summary (Copy & Paste to Discord)", lines.join("\n"), ui.ButtonSet.OK);
}

/**
 * One-click initialization/repair of all required tabs, headers, dropdowns, and Addon_Export!A1.
 */
function setupAllTabs() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var ui = SpreadsheetApp.getUi();

  // 1. Roster_And_Rolls
  var rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  if (!rosterSheet) {
    rosterSheet = ss.insertSheet("Roster_And_Rolls");
  }
  var rosterHeaders = [[
    "PlayerName", "Status", "Item_1_Name", "Item_1_ExtraRolls",
    "Item_2_Name", "Item_2_ExtraRolls", "Consecutive_Misses", "Last_Raid_Date",
  ]];
  rosterSheet.getRange(1, 1, 1, 8).setValues(rosterHeaders).setFontWeight("bold");
  rosterSheet.setFrozenRows(1);

  // Add dropdown data validation for Status column (rows 2..300)
  var statusRule = SpreadsheetApp.newDataValidation()
    .requireValueInList(["Member", "Recruit", "Alt", "Benched"], true)
    .setAllowInvalid(true)
    .build();
  rosterSheet.getRange(2, 2, 300, 1).setDataValidation(statusRule);

  // 2. CSV_Import
  var csvSheet = ss.getSheetByName("CSV_Import");
  if (!csvSheet) {
    csvSheet = ss.insertSheet("CSV_Import");
  }
  csvSheet.getRange(1, 1, 1, 6).setValues([["Name", "Class", "ItemId", "ItemName", "Note", "Plus"]]).setFontWeight("bold");
  csvSheet.setFrozenRows(1);

  // 3. Addon_Export (clear any accidental formula like #NAME? in A1)
  var exportSheet = ss.getSheetByName("Addon_Export");
  if (!exportSheet) {
    exportSheet = ss.insertSheet("Addon_Export");
  }
  var a1Formula = exportSheet.getRange("A1").getFormula();
  if (a1Formula) {
    exportSheet.getRange("A1").clearContent();
  }
  exportSheet.getRange("A2").setValue("Optional — Paste '/rsr won' string in A3 below to auto-apply on Weekly Commit:").setFontWeight("bold");
  writeAddonExport(ss);

  // 4. Aliases
  var aliasSheet = ss.getSheetByName("Aliases");
  if (!aliasSheet) {
    aliasSheet = ss.insertSheet("Aliases");
  }
  aliasSheet.getRange(1, 1, 1, 3).setValues([["Alias_Or_Alt_Name", "Roster_Character_Name", "Type"]]).setFontWeight("bold");
  aliasSheet.setFrozenRows(1);
  aliasSheet.setColumnWidth(1, 220);
  aliasSheet.setColumnWidth(2, 220);
  aliasSheet.setColumnWidth(3, 140);

  var aliasTypeRule = SpreadsheetApp.newDataValidation()
    .requireValueInList(["Alt", "Alias"], true)
    .setAllowInvalid(true)
    .build();
  aliasSheet.getRange(2, 3, 300, 1).setDataValidation(aliasTypeRule);

  ui.alert(
    "🚀 Sheet Setup & Repair Complete",
    "Verified and configured all 4 tabs:\n" +
      "• Roster_And_Rolls (with Status dropdowns)\n" +
      "• CSV_Import\n" +
      "• Addon_Export (cleared any formula errors in A1)\n" +
      "• Aliases (with Alt / Alias dropdowns)",
    ui.ButtonSet.OK
  );
}

/**
 * Interactive dialog to register an Alt character and link it to its Main on Roster_And_Rolls and Aliases.
 */
function linkAltDialog() {
  var ui = SpreadsheetApp.getUi();
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  if (!rosterSheet) {
    setupAllTabs();
    rosterSheet = ss.getSheetByName("Roster_And_Rolls");
  }

  var altResp = ui.prompt(
    "🔗 Register / Link Alt to Main (Step 1 of 2)",
    "Enter the Alt character's in-game name:",
    ui.ButtonSet.OK_CANCEL
  );
  if (altResp.getSelectedButton() !== ui.Button.OK) return;
  var altName = normName(altResp.getResponseText());
  if (!altName) return;

  var mainResp = ui.prompt(
    "🔗 Register / Link Alt to Main (Step 2 of 2)",
    "Enter the Main character's name on Roster_And_Rolls that '" + altName + "' belongs to:",
    ui.ButtonSet.OK_CANCEL
  );
  if (mainResp.getSelectedButton() !== ui.Button.OK) return;
  var mainName = normName(mainResp.getResponseText());
  if (!mainName) return;

  var roster = readRoster(rosterSheet);
  var statusValue = "Alt (" + mainName + ")";

  // 1. Add or update the Alt row on Roster_And_Rolls
  if (roster[altName]) {
    var existing = roster[altName];
    writePlayerRow(
      rosterSheet, existing.row, altName, statusValue,
      existing.item1, 0, existing.item2, 0, 0, existing.lastRaid
    );
  } else {
    var nextRow = Math.max(rosterSheet.getLastRow() + 1, 2);
    writePlayerRow(rosterSheet, nextRow, altName, statusValue, "", 0, "", 0, 0, "");
  }

  // 2. Add or update the mapping on Aliases tab
  var aliasSheet = ss.getSheetByName("Aliases");
  if (!aliasSheet) {
    aliasSheet = ss.insertSheet("Aliases");
    aliasSheet.getRange(1, 1, 1, 3).setValues([["Alias_Or_Alt_Name", "Roster_Character_Name", "Type"]]).setFontWeight("bold");
    aliasSheet.setFrozenRows(1);
  }

  var aliasData = aliasSheet.getDataRange().getValues();
  var updatedAliasRow = false;
  for (var r = 1; r < aliasData.length; r++) {
    if (normName(aliasData[r][0]) === altName) {
      aliasSheet.getRange(r + 1, 1, 1, 3).setValues([[altName, mainName, "Alt"]]);
      updatedAliasRow = true;
      break;
    }
  }
  if (!updatedAliasRow) {
    var nextAliasRow = Math.max(aliasSheet.getLastRow() + 1, 2);
    aliasSheet.getRange(nextAliasRow, 1, 1, 3).setValues([[altName, mainName, "Alt"]]);
  }

  writeAddonExport(ss);

  var mainNote = roster[mainName]
    ? "✓ Main '" + mainName + "' found on Roster_And_Rolls."
    : "⚠️ Note: '" + mainName + "' is not on Roster_And_Rolls yet — remember to add the Main row too!";

  ui.alert(
    "🔗 Alt Linked to Main",
    "Successfully linked Alt '" + altName + "' → Main '" + mainName + "':\n\n" +
      "• Roster_And_Rolls: " + altName + " set to Status '" + statusValue + "' (0 extra rolls)\n" +
      "• Aliases: " + altName + " | " + mainName + " | Alt\n" +
      "• " + mainNote,
    ui.ButtonSet.OK
  );
}

/**
 * Determine whether a player is a Recruit still within their 2-week trial
 * (i.e. they've attended fewer than RECRUIT_TRIAL_WEEKS raids).
 *
 * Checks:
 * 1. If accumulated rolls in either slot reach or exceed RECRUIT_TRIAL_WEEKS (2 raids),
 *    they have completed their trial.
 * 2. If an archive tab exists from >= 2 weeks ago containing the recruit, they've completed trial.
 * Otherwise, they are still within their 2-week trial period.
 */
function isRecruitInTrial(entry) {
  if (entry.status !== "Recruit") return false;

  // 1. If accumulated rolls in either slot reach or exceed RECRUIT_TRIAL_WEEKS (2 raids),
  // they've attended 2+ raids and completed their trial.
  var maxRolls = Math.max(entry.rolls1 || 0, entry.rolls2 || 0);
  if (maxRolls >= RECRUIT_TRIAL_WEEKS) return false;

  // 2. Check archive snapshot tabs to see if the recruit appeared >= 2 weeks ago.
  try {
    var ss = SpreadsheetApp.getActiveSpreadsheet();
    if (ss) {
      var sheets = ss.getSheets();
      var cutoff = new Date();
      cutoff.setDate(cutoff.getDate() - (RECRUIT_TRIAL_WEEKS * 7));

      for (var i = 0; i < sheets.length; i++) {
        var match = sheets[i].getName().match(/^Archive_(\d{4}-\d{2}-\d{2})/);
        if (match) {
          var archDate = new Date(match[1]);
          if (archDate <= cutoff) {
            var archData = sheets[i].getDataRange().getValues();
            for (var r = 1; r < archData.length; r++) {
              if (normName(archData[r][COL.NAME]) === normName(entry.name)) {
                return false;
              }
            }
          }
        }
      }
    }
  } catch (err) {
    // Spreadsheet unavailable during unit test or headless execution
  }

  return true;
}

// ── Menu ────────────────────────────────────────────────────────────────────────

/**
 * Add a custom menu to the spreadsheet for easy access.
 */
function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu("Soft Reserve+")
    .addItem("🔍 Preview & Review (Dry Run)", "previewWeeklySoftReserves")
    .addItem("⚡ Process Weekly SRs (Commit)", "processWeeklySoftReserves")
    .addItem("📋 View / Copy Addon String", "showExportStringDialog")
    .addSeparator()
    .addItem("📥 Import Won Items String (/srp won or /rsr won)", "importWonItemsDialog")
    .addItem("🏆 Mark Item Won (Manual)", "markItemWonDialog")
    .addItem("🔗 Register / Link Alt to Main", "linkAltDialog")
    .addItem("🌴 Excuse Absence / Vacation", "excuseAbsenceDialog")
    .addItem("🎓 Check Recruit Graduation", "checkRecruitGraduation")
    .addItem("📊 Streak Leaderboard & Stats", "showLeaderboardAndStats")
    .addItem("📢 Generate Discord Summary", "generateDiscordSummary")
    .addSeparator()
    .addItem("🚀 Initialize / Repair Sheet Tabs", "setupAllTabs")
    .addItem("📦 Create Backup Snapshot", "createRosterSnapshot")
    .addItem("🧹 Clean & Sort Roster", "formatAndCleanRoster")
    .addItem("📋 Setup Aliases Tab", "setupAliasesTab")
    .addItem("🔄 Refresh Addon Export", "writeAddonExport")
    .addToUi();
}
