-- Unit test suite for RollingSR (Classes/RollingSR.lua)
-- Run with: Scripts\bin\lua5.1.exe Scripts\test_rolling_sr.lua

strlower = string.lower;
strtrim = function (s) return (s:gsub("^%s+", ""):gsub("%s+$", "")); end
tinsert = table.insert;
Gargul_L = { CHAT = { ["Stop your rolls!"] = "Stop your rolls!", }, };

local chatLog = {};
local messageLog = {};
local warningLog = {};
local broadcastedMessages = {};

local mockRollOff = {
    inProgress = false,
    CurrentRollOff = {
        itemName = "Deathbringer's Will",
        itemLink = "|cffa335ee|Hitem:50363::::::::80:::::|h[Deathbringer's Will]|h|r",
        itemID = 50363,
        Rolls = {},
    },
    listenForRolls = function () end,
    refreshRollsTable = function () end,
    processRoll = function (_, msg)
        local player, amount = msg:match("^(%S+) rolls (%d+) %(1%-100%)$");
        if (player and amount) then
            local r = { player = player, amount = tonumber(amount), };
            if (_G.TestGL.RollingSR:acceptRoll(r)) then
                tinsert(_G.TestMockRollOff.CurrentRollOff.Rolls, r);
            end
        end
    end,
};
_G.TestMockRollOff = mockRollOff;

local mockSoftRes = {
    available = function () return true; end,
    itemIDIsReservedByPlayer = function (_, _, playerName)
        local p = strlower(playerName:match("^([^-]+)") or playerName);
        return p == "thrall" or p == "arthas" or p == "pugman" or p == "puglady";
    end,
};

local GL = {
    Events = { register = function () end, },
    empty = function (_, v) return v == nil or v == "" or (type(v) == "table" and next(v) == nil); end,
    disambiguateName = function (_, n) return tostring(n or ""):match("^([^-]+)") or tostring(n or ""); end,
    capitalize = function (_, n) return n:sub(1, 1):upper() .. n:sub(2):lower(); end,
    sendChatMessage = function (_, msg, channel, _, target)
        tinsert(chatLog, { msg = msg, channel = channel, target = target, });
    end,
    debug = function () end,
    message = function (_, msg)
        tinsert(messageLog, tostring(msg));
        print("[TEST GL:message] " .. tostring(msg));
    end,
    success = function (_, msg) print("[TEST GL:success] " .. tostring(msg)); end,
    warning = function (_, msg)
        tinsert(warningLog, tostring(msg));
        print("[TEST GL:warning] " .. tostring(msg));
    end,
    getItemNameFromLink = function (_, link) return tostring(link):match("%[(.-)%]") or link; end,
    DB = {
        get = function () return {}; end,
        set = function () end,
    },
    Data = {
        Constants = {
            Comm = {
                Actions = {
                    broadcastRollingSRData = "BROADCAST_RSR",
                },
            },
        },
    },
    CommMessage = {
        new = function (opts)
            return {
                send = function ()
                    tinsert(broadcastedMessages, opts);
                end,
            };
        end,
    },
    RollOff = mockRollOff,
    SoftRes = mockSoftRes,
    User = { isInGroup = true, isMasterLooter = true, },
};
_G.TestGL = GL;

local chunk = assert(loadfile("Classes/RollingSR.lua"));
chunk("Gargul", GL);
local R = GL.RollingSR;
R:_init();

print("--- Test 1: Parse Import String ---");
assert(R:parseImportString("Thrall:Deathbringer's Will=2,Solace of the Defeated=0;Arthas:Deathbringer's Will=1;"));
assert(R:hasData());
assert(R:tracksItem("Deathbringer's Will"));
assert(R:tracksItem("[Deathbringer's Will]"));
assert(not R:tracksItem("Invincible's Reins"));
assert(R:isGuildPlayer("thrall"));
assert(R:isGuildPlayer("arthas"));
assert(not R:isGuildPlayer("pugman"));
assert(R:getExtraRolls("Thrall", "Deathbringer's Will") == 2);
assert(R:allowedPhase2Rolls("Thrall", "Deathbringer's Will") == 3);
assert(R:allowedPhase2Rolls("Arthas", "Deathbringer's Will") == 2);
print("Test 1 passed!");

print("--- Test 2: Phase 1 Rolls and Gating ---");
R:beginPhase1();
assert(R:isPhase1());
assert(not R:isPhase2());

local rRandom = { player = "RandomGuy", amount = 100 };
assert(not R:acceptRoll(rRandom));

local rThrall = { player = "Thrall", amount = 85 };
assert(R:acceptRoll(rThrall));
assert(rThrall.rsrPhase == 1);
assert(rThrall.rsrRound == 0);
tinsert(mockRollOff.CurrentRollOff.Rolls, rThrall);

local rThrall2 = { player = "Thrall", amount = 99 };
assert(not R:acceptRoll(rThrall2));

local rPug = { player = "Pugman", amount = 85 };
assert(R:acceptRoll(rPug));
tinsert(mockRollOff.CurrentRollOff.Rolls, rPug);

local rArthas = { player = "Arthas", amount = 70 };
assert(R:acceptRoll(rArthas));
tinsert(mockRollOff.CurrentRollOff.Rolls, rArthas);
print("Test 2 passed!");

print("--- Test 3: Phase 1 Tie-break ---");
chatLog = {};
local continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == true);
assert(R:isPhase1());
assert(R.round == 1);
assert(R.TiedPlayers["thrall"]);
assert(R.TiedPlayers["pugman"]);
assert(not R.TiedPlayers["arthas"]);

local rArthasTie = { player = "Arthas", amount = 90 };
assert(not R:acceptRoll(rArthasTie));

local rThrallTie = { player = "Thrall", amount = 92 };
assert(R:acceptRoll(rThrallTie));
assert(rThrallTie.classification == "TIE");
tinsert(mockRollOff.CurrentRollOff.Rolls, rThrallTie);

local rPugTie = { player = "Pugman", amount = 80 };
assert(R:acceptRoll(rPugTie));
tinsert(mockRollOff.CurrentRollOff.Rolls, rPugTie);
print("Test 3 passed!");

print("--- Test 4: Transition to Phase 2 (Guild won tie-break) ---");
chatLog = {};
continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == true);
assert(R:isPhase2());
assert(not R:isPhase1());
print("Test 4 passed!");

print("--- Test 5: Phase 2 Roll Limits ---");
local rPugP2 = { player = "Pugman", amount = 100 };
assert(not R:acceptRoll(rPugP2));

local rT1 = { player = "Thrall", amount = 88 };
local rT2 = { player = "Thrall", amount = 94 };
local rT3 = { player = "Thrall", amount = 91 };
local rT4 = { player = "Thrall", amount = 99 };
assert(R:acceptRoll(rT1));
tinsert(mockRollOff.CurrentRollOff.Rolls, rT1);
assert(R:acceptRoll(rT2));
tinsert(mockRollOff.CurrentRollOff.Rolls, rT2);
assert(R:acceptRoll(rT3));
tinsert(mockRollOff.CurrentRollOff.Rolls, rT3);
assert(not R:acceptRoll(rT4));

local rA1 = { player = "Arthas", amount = 96 };
local rA2 = { player = "Arthas", amount = 75 };
local rA3 = { player = "Arthas", amount = 98 };
assert(R:acceptRoll(rA1));
tinsert(mockRollOff.CurrentRollOff.Rolls, rA1);
assert(R:acceptRoll(rA2));
tinsert(mockRollOff.CurrentRollOff.Rolls, rA2);
assert(not R:acceptRoll(rA3));
print("Test 5 passed!");

print("--- Test 6: Stop Phase 2 & Winner Determination ---");
chatLog = {};
continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == false);
assert(not R:isActive());

local foundWinner = false;
for _, entry in ipairs(chatLog) do
    if entry.msg:find("Arthas wins") and entry.msg:find("96") then
        foundWinner = true;
    end
end
assert(foundWinner, "Winner announcement for Arthas at 96 not found in chat log!");

for _, r in ipairs(mockRollOff.CurrentRollOff.Rolls) do
    assert(r.player == "Thrall" or r.player == "Arthas");
    assert((r.rsrRound or 0) == 0);
end
print("Test 6 passed!");

print("--- Test 7: Pug outright wins Phase 1 ---");
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
local rPugWin = { player = "Puglady", amount = 99 };
local rThrallLose = { player = "Thrall", amount = 50 };
assert(R:acceptRoll(rPugWin));
tinsert(mockRollOff.CurrentRollOff.Rolls, rPugWin);
assert(R:acceptRoll(rThrallLose));
tinsert(mockRollOff.CurrentRollOff.Rolls, rThrallLose);

chatLog = {};
continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == false);
assert(not R:isActive());

local foundPugWin = false;
for _, entry in ipairs(chatLog) do
    if entry.msg:find("Puglady wins") and entry.msg:find("Phase 1") then
        foundPugWin = true;
    end
end
assert(foundPugWin, "Pug winner announcement not found!");
print("Test 7 passed!");

print("--- Test 8: Item Awarded Resets Extra Rolls ---");
assert(R:getExtraRolls("Thrall", "Deathbringer's Will") == 2);
R:onItemAwarded("Thrall", "Deathbringer's Will");
assert(R:getExtraRolls("Thrall", "Deathbringer's Will") == 0);
assert(R:allowedPhase2Rolls("Thrall", "Deathbringer's Will") == 1);
print("Test 8 passed!");

print("--- Test 9: getStatusText in Phase 1 and Phase 2 ---");
mockSoftRes.byItemLink = function ()
    return { "Thrall", "Arthas", "Pugman" };
end;
R:beginPhase1();
assert(R:getStatusText("Deathbringer's Will"):find("Phase 1: 0/3 rolled", 1, true));
R:acceptRoll({ player = "Thrall", amount = 50 });
assert(R:getStatusText("Deathbringer's Will"):find("Phase 1: 1/3 rolled", 1, true));

R.round = 1;
R.TiedPlayers = { thrall = true, pugman = true };
R.RollCounts = {};
assert(R:getStatusText("Deathbringer's Will"):find("Tie-Break: 0/2 rolled", 1, true));
R:acceptRoll({ player = "Thrall", amount = 80 });
assert(R:getStatusText("Deathbringer's Will"):find("Tie-Break: 1/2 rolled", 1, true));

R.phase = 2;
R.round = 0;
R.RollCounts = {};
R.ExtraRolls = {
    thrall = { ["deathbringer's will"] = 0 },
    arthas = { ["deathbringer's will"] = 1 },
};
assert(R:getStatusText("Deathbringer's Will"):find("Phase 2: 0/3 rolls", 1, true));
R:acceptRoll({ player = "Thrall", amount = 90 });
R:acceptRoll({ player = "Arthas", amount = 91 });
R:acceptRoll({ player = "Arthas", amount = 92 });
assert(R:getStatusText("Deathbringer's Will"):find("Phase 2: 3/3 (All in!)", 1, true));
print("Test 9 passed!");

print("--- Test 10: Slash Command /gl rsr & Auto-Broadcast ---");
broadcastedMessages = {};
R:handleCommand("clear");
assert(R:countPlayers() == 0);
R:handleCommand("Jaina:Staff=1;Sylvanas:Bow=2;");
assert(R:countPlayers() == 2);
assert(R:getExtraRolls("Jaina", "Staff") == 1);
assert(R:getExtraRolls("Sylvanas", "Bow") == 2);
assert(#broadcastedMessages == 1, "Importing via /gl rsr should auto-broadcast!");
assert(broadcastedMessages[1].channel == "GROUP");
print("Test 10 passed!");

print("--- Test 11: Comms Receive Broadcast ---");
R:receiveBroadcast({
    Sender = { isSelf = false, name = "RaidOfficer" },
    content = "Illidan:Glaive=4;",
});
assert(R:countPlayers() == 1);
assert(R:getExtraRolls("Illidan", "Glaive") == 4);
print("Test 11 passed!");

print("--- Test 12: Untracked Item Roll-Off ---");
assert(not R:tracksItem("Bracers of the Innocent"));
R:resetPhase();
assert(not R:isActive());
assert(R:acceptRoll({ player = "RandomGuy", amount = 42 }));
print("Test 12 passed!");

print("--- Test 13: Guild-Only Tie in Phase 1 Skips Tie-Break ---");
R:parseImportString("Thrall:Deathbringer's Will=2;Arthas:Deathbringer's Will=1;");
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
local rollThrall = { player = "Thrall", amount = 100 };
local rollArthas = { player = "Arthas", amount = 100 };
assert(R:acceptRoll(rollThrall));
assert(R:acceptRoll(rollArthas));
tinsert(mockRollOff.CurrentRollOff.Rolls, rollThrall);
tinsert(mockRollOff.CurrentRollOff.Rolls, rollArthas);

continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == true);
assert(R:isPhase2(), "Guild-only tie should advance directly to Phase 2!");
assert(R.round == 0, "Round should be 0 in Phase 2!");
print("Test 13 passed!");

print("--- Test 14: Double Tie-Break (Pug + Guild Tie Twice) ---");
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
local r1 = { player = "Thrall", amount = 95 };
local r2 = { player = "Pugman", amount = 95 };
assert(R:acceptRoll(r1));
assert(R:acceptRoll(r2));
tinsert(mockRollOff.CurrentRollOff.Rolls, r1);
tinsert(mockRollOff.CurrentRollOff.Rolls, r2);

continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == true);
assert(R:isPhase1() and R.round == 1);

local tb1_1 = { player = "Thrall", amount = 88 };
local tb1_2 = { player = "Pugman", amount = 88 };
assert(R:acceptRoll(tb1_1));
assert(R:acceptRoll(tb1_2));
tinsert(mockRollOff.CurrentRollOff.Rolls, tb1_1);
tinsert(mockRollOff.CurrentRollOff.Rolls, tb1_2);

continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == true);
assert(R:isPhase1() and R.round == 2, "Second tie should increment round to 2!");

local tb2_1 = { player = "Thrall", amount = 90 };
local tb2_2 = { player = "Pugman", amount = 70 };
assert(R:acceptRoll(tb2_1));
assert(R:acceptRoll(tb2_2));
tinsert(mockRollOff.CurrentRollOff.Rolls, tb2_1);
tinsert(mockRollOff.CurrentRollOff.Rolls, tb2_2);

continues = R:handleStop(mockRollOff.CurrentRollOff);
assert(continues == true);
assert(R:isPhase2(), "Thrall won second tie-break, should advance to Phase 2!");
assert(R.round == 0, "Round must be reset to 0 in Phase 2!");
print("Test 14 passed!");

print("--- Test 15: Typographic & Unicode Curly Quote Matching ---");
R:parseImportString("Varian:Deathbringer’s Will=3;");
assert(R:getExtraRolls("Varian", "Deathbringer's Will") == 3);
assert(R:tracksItem("Deathbringer's Will") == true);
assert(R:tracksItem("Deathbringer’s Will") == true);
print("Test 15 passed!");

print("--- Test 16: Irregular Whitespace & Delimiter Parsing ---");
R:handleCommand("clear");
R:parseImportString("   Uther   :   Hammer of the Naaru = 2 , Shield of the Righteous = 1 ;   ");
assert(R:countPlayers() == 1);
assert(R:getExtraRolls("Uther", "Hammer of the Naaru") == 2);
assert(R:getExtraRolls("Uther", "Shield of the Righteous") == 1);
print("Test 16 passed!");

print("--- Test 17: In-Game Test Mode (/rsr test & /rsr sim) ---");
local importedCSV = nil;
mockSoftRes.importCSVData = function (_, data) importedCSV = data; return true; end;
GL.User.name = "MyTester";
R:handleCommand("test");
assert(R:countPlayers() == 3, "Test mode should load 3 guild characters (2 Mains + 1 Alt)!");
assert(R:getExtraRolls("MyTester", "Brutality Blade") == 2, "Tester should have 2 bonus rolls!");
assert(R:getExtraRolls("Guildmate", "Brutality Blade") == 1, "Guildmate should have 1 bonus roll!");
assert(R:isAlt("Guildalt") == true and R:getExtraRolls("Guildalt", "Brutality Blade") == 0, "Guildalt should be an Alt with 0 bonus rolls!");
assert(not R:isGuildPlayer("Pugman"), "Pugman should not be a guild player (treated as Pug)!");
assert(importedCSV ~= nil and importedCSV:find("Brutality Blade") and importedCSV:find("Talisman of Ephemeral Power"), "SoftRes CSV should load Vanilla Molten Core items!");

mockRollOff.inProgress = true;
mockRollOff.CurrentRollOff.itemName = "Brutality Blade";
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
R:handleCommand("sim");
assert(#mockRollOff.CurrentRollOff.Rolls == 3, "Sim should inject Pugman, Guildalt, and Guildmate rolls!");
mockRollOff.inProgress = false;
mockRollOff.CurrentRollOff.itemName = "Deathbringer's Will";
print("Test 17 passed!");

print("--- Test 18: Whisper Auto-Responder (!rsr / !rolls) ---");
R:parseImportString("Thrall:Deathbringer's Will=2,Solace of the Defeated=0;Dyalalt*alt:Deathbringer's Will=0;");
chatLog = {};
R:handleWhisperCommand("!rsr", "Thrall-Whitemane");
assert(#chatLog == 1, "Should reply to !rsr whisper!");
assert(chatLog[1].channel == "WHISPER");
assert(chatLog[1].target == "Thrall-Whitemane");
assert(chatLog[1].msg:find("deathbringer's will (+2 bonus, 3 Phase 2 rolls)", 1, true));

chatLog = {};
R:handleWhisperCommand("!rsr", "Dyalalt");
assert(#chatLog == 1 and chatLog[1].msg:find("Guild Alt", 1, true), "Should reply with Guild Alt status!");

chatLog = {};
R:handleWhisperCommand("!rolls", "UnknownPug-Whitemane");
assert(#chatLog == 1, "Should reply to unlisted player!");
assert(chatLog[1].msg:find("No stored bonus rolls", 1, true));

chatLog = {};
R:handleWhisperCommand("hello there", "Thrall");
assert(#chatLog == 0, "Normal whispers must be ignored!");
print("Test 18 passed!");

print("--- Test 19: Inspection Commands (/rsr list & /rsr <player>) ---");
messageLog = {};
warningLog = {};
R:handleCommand("list");
assert(#messageLog >= 2, "/rsr list should output loaded players!");
messageLog = {};
R:handleCommand("Thrall");
assert(#messageLog == 1 and messageLog[1]:find("Thrall:", 1, true), "/rsr Thrall (2 words) should print Thrall's rolls!");
messageLog = {};
R:handleCommand("Dyalalt");
assert(#messageLog == 1 and messageLog[1]:find("[Alt]", 1, true), "/rsr Dyalalt should show [Alt] badge!");
R:handleCommand("NonExistentPug");
assert(#warningLog == 1 and warningLog[1]:find("treated as Pug", 1, true), "Checking unlisted player should warn!");
print("Test 19 passed!");

print("--- Test 20: Realm-Qualified Player Name Disambiguation ---");
assert(R:isGuildPlayer("Thrall-Whitemane") == true);
assert(R:getExtraRolls("Thrall-Whitemane", "Deathbringer's Will") == 2);
assert(R:allowedPhase2Rolls("Thrall-Whitemane", "Deathbringer's Will") == 3);
print("Test 20 passed!");

print("--- Test 21: Phase 2 Tie Between Guild Members ---");
R:parseImportString("Thrall:Deathbringer's Will=1;Arthas:Deathbringer's Will=1;");
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
local p1T = { player = "Thrall", amount = 80 };
local p1A = { player = "Arthas", amount = 75 };
assert(R:acceptRoll(p1T));
assert(R:acceptRoll(p1A));
tinsert(mockRollOff.CurrentRollOff.Rolls, p1T);
tinsert(mockRollOff.CurrentRollOff.Rolls, p1A);
assert(R:handleStop(mockRollOff.CurrentRollOff) == true);
assert(R:isPhase2());

local p2T = { player = "Thrall", amount = 98 };
local p2A = { player = "Arthas", amount = 98 };
assert(R:acceptRoll(p2T));
assert(R:acceptRoll(p2A));
tinsert(mockRollOff.CurrentRollOff.Rolls, p2T);
tinsert(mockRollOff.CurrentRollOff.Rolls, p2A);

chatLog = {};
assert(R:handleStop(mockRollOff.CurrentRollOff) == false);
local foundTieAnnouncement = false;
for _, entry in ipairs(chatLog) do
    if entry.msg:find("tie at 98") then
        foundTieAnnouncement = true;
    end
end
assert(foundTieAnnouncement, "Phase 2 tie announcement should be sent!");
print("Test 21 passed!");

print("--- Test 22: Mains vs. Alts Complete Rolling Rules ---");
-- 22a: Alts never accumulate stacking rolls (even if import string has >0)
R:parseImportString("Thrall:Deathbringer's Will=2;Dyalalt*alt:Deathbringer's Will=5;");
assert(R:isMain("Thrall") == true and R:isAlt("Thrall") == false);
assert(R:isAlt("Dyalalt") == true and R:isMain("Dyalalt") == false and R:isGuildPlayer("Dyalalt") == true);
assert(R:getExtraRolls("Dyalalt", "Deathbringer's Will") == 0, "Alts must never accumulate stacking rolls!");

-- 22b: Alt beats Pug in Phase 1 (99 vs 90), Main rolls 30 in Phase 1 -> Triggers Phase 2 -> Main wins over Alt!
mockSoftRes._byItemID = { [50363] = { "Thrall", "Dyalalt", "Pugman" } };
mockSoftRes.byItemID = function (_, id) return mockSoftRes._byItemID[id] or {}; end;
mockRollOff.CurrentRollOff.itemID = 50363;
mockRollOff.CurrentRollOff.itemName = "Deathbringer's Will";
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();

local altRollP1 = { player = "Dyalalt", amount = 99 };
local pugRollP1 = { player = "Pugman", amount = 90 };
local mainRollP1 = { player = "Thrall", amount = 30 };
assert(R:acceptRoll(altRollP1) == true, "Alt should be allowed to roll in Phase 1 when Pugs are present!");
assert(R:acceptRoll(pugRollP1) == true, "Pug should be allowed to roll in Phase 1!");
assert(R:acceptRoll(mainRollP1) == true, "Main should be allowed to roll in Phase 1!");
tinsert(mockRollOff.CurrentRollOff.Rolls, altRollP1);
tinsert(mockRollOff.CurrentRollOff.Rolls, pugRollP1);
tinsert(mockRollOff.CurrentRollOff.Rolls, mainRollP1);

-- Alt won Phase 1 -> same as regular guild member winning Phase 1 -> transitions to Phase 2!
assert(R:handleStop(mockRollOff.CurrentRollOff) == true, "Alt winning Phase 1 must trigger Phase 2!");
assert(R:isPhase2() == true, "Must be in Phase 2 after Alt beats Pug in Phase 1!");

-- In Phase 2, Alt cannot roll or win because a Main (Thrall) reserved the item
assert(R:acceptRoll({ player = "Dyalalt", amount = 100 }) == false, "Alt must NOT be allowed to roll in Phase 2 when a Main reserved the item!");
local mainRollP2 = { player = "Thrall", amount = 55 };
assert(R:acceptRoll(mainRollP2) == true, "Main can roll in Phase 2!");
tinsert(mockRollOff.CurrentRollOff.Rolls, mainRollP2);

chatLog = {};
assert(R:handleStop(mockRollOff.CurrentRollOff) == false, "Phase 2 should finish!");
assert(#mockRollOff.CurrentRollOff.Rolls == 2, "Only Thrall's 2 rolls should remain (Alt's 99 and Pug's 90 filtered out)!");
assert(chatLog[#chatLog].msg:find("Thrall wins") and chatLog[#chatLog].msg:find("55"), "Main (Thrall) must win with 55 over Alt's Phase 1 99!");

-- 22c: When NO Pugs reserved the item (only Main and Alt), Alt is blocked in Phase 1
mockSoftRes._byItemID = { [50363] = { "Thrall", "Dyalalt" } };
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
assert(R:acceptRoll({ player = "Dyalalt", amount = 80 }) == false, "Alt must not roll in Phase 1 when no Pugs reserved the item and a Main reserved it!");
assert(R:acceptRoll({ player = "Thrall", amount = 50 }) == true, "Main can roll when no Pugs are present!");

-- 22d: When NO Mains reserved the item (only Alt and Pug), Alt can win in Phase 2!
R:parseImportString("Dyalalt*alt:Deathbringer's Will=0;");
mockSoftRes._byItemID = { [50363] = { "Dyalalt", "Pugman" } };
mockRollOff.CurrentRollOff.Rolls = {};
R:beginPhase1();
local altOnlyP1 = { player = "Dyalalt", amount = 85 };
local pugOnlyP1 = { player = "Pugman", amount = 70 };
assert(R:acceptRoll(altOnlyP1) == true);
assert(R:acceptRoll(pugOnlyP1) == true);
tinsert(mockRollOff.CurrentRollOff.Rolls, altOnlyP1);
tinsert(mockRollOff.CurrentRollOff.Rolls, pugOnlyP1);
assert(R:handleStop(mockRollOff.CurrentRollOff) == true);
assert(R:isPhase2() == true);
chatLog = {};
assert(R:handleStop(mockRollOff.CurrentRollOff) == false);
assert(chatLog[#chatLog].msg:find("Dyalalt wins"), "Alt should win when no Mains reserved the item!");
mockSoftRes.byItemID = nil;
print("Test 22 passed!");

print("--- Test 23: In-Game Award Export String (/rsr won) ---");
R:handleCommand("clear");
R:parseImportString("Thrall:Deathbringer's Will=3;Jaina:Phylactery of the Nameless Lich=2;");
R:onItemAwarded("Thrall", "|cffa335ee|Hitem:50363::::::::80:::::|h[Deathbringer's Will]|h|r");
R:onItemAwarded("Jaina", "[Phylactery of the Nameless Lich]");
assert(R:getAwardExportString() == "Thrall:Deathbringer's Will;Jaina:Phylactery of the Nameless Lich;", "Award export string should list won items!");
messageLog = {};
R:handleCommand("won");
assert(#messageLog >= 1 and messageLog[1]:find("Thrall:Deathbringer's Will;Jaina:Phylactery of the Nameless Lich;", 1, true), "/rsr won should print the export string!");
print("Test 23 passed!");

print("--- Test 24: Configurable Max Accumulated Rolls Cap (/rsr max) ---");
assert(R.maxExtraRolls == 100, "Default maxExtraRolls cap should be 100!");
R:parseImportString("Thrall:Deathbringer's Will=150;");
assert(R:getExtraRolls("Thrall", "Deathbringer's Will") == 100, "Rolls exceeding 100 should be capped at 100!");
R:handleCommand("max 15");
assert(R.maxExtraRolls == 15, "/rsr max 15 should update cap to 15!");
assert(R:getExtraRolls("Thrall", "Deathbringer's Will") == 15, "getExtraRolls should respect updated cap of 15!");
R:handleCommand("max 100");
assert(R.maxExtraRolls == 100);
print("Test 24 passed!");

print("--- Test 25: 1-2 Word /rsr Subcommands (/rsr tie, /rsr guild, /rsr raid) ---");
broadcastedMessages = {};
R:handleCommand("guild");
assert(#broadcastedMessages == 1 and broadcastedMessages[1].channel == "GUILD", "/rsr guild should broadcast to GUILD!");
broadcastedMessages = {};
R:handleCommand("raid");
assert(#broadcastedMessages == 1 and broadcastedMessages[1].channel == "GROUP", "/rsr raid should broadcast to GROUP!");
print("Test 25 passed!");

print("--- Test 26: Configurable Alt Roll Accumulation (/rsr altrolls) ---");
R:parseImportString("Thrall:Deathbringer's Will=2;Dyalalt*alt:Deathbringer's Will=3,Phylactery of the Nameless Lich=2;");
assert(R.altsAccrueRolls == false, "Default altsAccrueRolls must be false!");
assert(R:getExtraRolls("Dyalalt", "Phylactery of the Nameless Lich") == 0, "When altsAccrueRolls is false, Alt has 0 bonus rolls!");
R:handleCommand("altrolls on");
assert(R.altsAccrueRolls == true, "/rsr altrolls on must enable altsAccrueRolls!");
assert(R:getExtraRolls("Dyalalt", "Phylactery of the Nameless Lich") == 2, "When altsAccrueRolls is true, Alt gets their stored +2 bonus rolls!");
assert(R:allowedPhase2Rolls("Dyalalt", "Phylactery of the Nameless Lich") == 3, "Alt gets 1 + 2 = 3 rolls in Phase 2 when no Main reserved the item!");
-- Verify Alt STILL cannot roll in Phase 2 when a Main reserved the item (Deathbringer's Will)
mockRollOff.CurrentRollOff.itemName = "Deathbringer's Will";
assert(R:isPhase2Eligible("Dyalalt") == false, "Even with altrolls ON, Alt can never win over a Main!");
-- Verify Alt CAN roll 3 times in Phase 2 when NO Main reserved the item (Phylactery of the Nameless Lich)
mockRollOff.CurrentRollOff.itemName = "Phylactery of the Nameless Lich";
assert(R:isPhase2Eligible("Dyalalt") == true, "Alt is Phase 2 eligible when no Main reserved the item!");
R:handleCommand("altrolls off");
assert(R.altsAccrueRolls == false, "/rsr altrolls off must disable altsAccrueRolls!");
assert(R:getExtraRolls("Dyalalt", "Phylactery of the Nameless Lich") == 0);
print("Test 26 passed!");

print("--- Test 27: In-Game Simulator Modes (/rsr simpug, /rsr simalt, /rsr simwon) ---");
R:handleCommand("test");
mockRollOff.inProgress = true;
mockRollOff.CurrentRollOff.itemID = 18832;
mockRollOff.CurrentRollOff.itemName = "Brutality Blade";
mockRollOff.CurrentRollOff.itemLink = "[Brutality Blade]";
mockRollOff.CurrentRollOff.Rolls = {};
mockRollOff.processRoll = function (_, msg)
    local p, amt = msg:match("^(%S+) rolls (%d+)");
    if p and amt then
        local r = { player = p, amount = tonumber(amt) };
        if R:acceptRoll(r) then
            tinsert(mockRollOff.CurrentRollOff.Rolls, r);
        end
    end
end;
R:beginPhase1();
R:handleCommand("simpug");
assert(R:handleStop(mockRollOff.CurrentRollOff) == false, "/rsr simpug should result in Pugman winning Phase 1 outright!");
R:handleCommand("simwon");
assert(R:getAwardExportString():find("Brutality Blade", 1, true) ~= nil, "/rsr simwon should record a won item for /rsr won!");
print("Test 27 passed!");

print("\nALL 27 ROLLING SR UNIT TESTS PASSED SUCCESSFULLY!");
