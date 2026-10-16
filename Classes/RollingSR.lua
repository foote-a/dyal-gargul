local L = Gargul_L;

---@type GL
local _, GL = ...;

local PHASE_NONE = 0;
local PHASE_ONE = 1;
local PHASE_TWO = 2;

---@class RollingSR
local RollingSR = {
    _initialized = false,

    -- { [lowercasePlayerName] = { [lowercaseItemName] = extraRolls, }, }
    ExtraRolls = {},

    -- { [lowercasePlayerName] = true, }
    Alts = {},

    -- { [lowercasePlayerName] = true, }
    Recruits = {},

    -- { { player = "Thrall", item = "Deathbringer's Will", }, }
    AwardedItems = {},

    -- Configurable cap on accumulated bonus rolls per item
    maxExtraRolls = 100,

    -- Configurable toggle for whether Alts can accrue and use stacking bonus rolls (default false)
    altsAccrueRolls = false,

    phase = PHASE_NONE,

    -- Phase 1 tie-break round (0 = regular Phase 1 rolls)
    round = 0,

    -- Players allowed to roll in the current tie-break: { [lowercaseName] = true, }
    TiedPlayers = nil,

    -- Rolls counted per player in the current phase/round
    RollCounts = {},
};
GL.RollingSR = RollingSR; ---@type RollingSR

---@param name string
---@return string
local function normalizeName(name)
    return strlower(GL:disambiguateName(tostring(name or "")));
end

---@param itemName string
---@return string
local function normalizeItem(itemName)
    local s = strlower(strtrim(tostring(itemName or ""):match("%[(.-)%]") or tostring(itemName or "")));
    -- Normalize multi-byte UTF-8 curly quotes to standard ASCII apostrophe
    s = s:gsub("\226\128\153", "'");
    s = s:gsub("\226\128\152", "'");
    s = s:gsub("[`'´]", "'");
    s = s:gsub("%s+", " ");
    return s;
end

---@return nil
function RollingSR:_init()
    if (self._initialized) then
        return;
    end

    -- Restore saved extra rolls across /reload or relog
    self.ExtraRolls = GL.DB:get("RollingSR.ExtraRolls", {}) or {};
    self.Alts = GL.DB:get("RollingSR.Alts", {}) or {};
    self.Recruits = GL.DB:get("RollingSR.Recruits", {}) or {};
    self.AwardedItems = GL.DB:get("RollingSR.AwardedItems", {}) or {};
    self.maxExtraRolls = tonumber(GL.DB:get("RollingSR.maxExtraRolls", 100)) or 100;
    self.altsAccrueRolls = GL.DB:get("RollingSR.altsAccrueRolls", false) == true;
    self.rawImportString = GL.DB:get("RollingSR.rawImportString", "") or "";

    GL.Events:register("RollingSRRollOffStarted", "GL.ROLLOFF_STARTED", function ()
        local currentItem = GL.RollOff.CurrentRollOff.itemName or GL.RollOff.CurrentRollOff.itemLink;
        if (self:tracksItem(currentItem)) then
            self:beginPhase1();
        else
            self:resetPhase();
        end
    end);

    GL.Events:register("RollingSRRollAccepted", "GL.ROLLOFF_ROLL_ACCEPTED", function ()
        if (self:isActive() and GL.RollOff:startedByMe()) then
            GL.MasterLooterUI:updateWidgets();
        end
    end);

    GL.Events:register("RollingSRSoftResCleared", "GL.SOFTRES_CLEARED", function ()
        self:clear();
    end);

    GL.Events:register("RollingSRItemAwarded", "GL.ITEM_AWARDED", function (_, AwardEntry)
        if (AwardEntry and AwardEntry.winner and AwardEntry.itemLink) then
            self:onItemAwarded(AwardEntry.winner, AwardEntry.itemLink);
        end
    end);

    GL.Events:register("RollingSRWhisperListener", "CHAT_MSG_WHISPER", function (_, message, sender)
        if (self:hasData() and (not GL.User or not GL.User.isInGroup or GL.User.isMasterLooter or GL.User.hasAssist)) then
            self:handleWhisperCommand(message, sender);
        end
    end);

    self._initialized = true;
end

--- Parse "Player:Item=Rolls,Item=Rolls;AltPlayer*alt:Item=0;" into ExtraRolls and Alts
---
---@param data string
---@return boolean
function RollingSR:parseImportString(data)
    if (GL:empty(data)) then
        return false;
    end

    local Parsed = {};
    local ParsedAlts = {};
    local ParsedRecruits = {};
    local cap = tonumber(self.maxExtraRolls) or 100;

    for entry in data:gmatch("[^;]+") do
        local rawPlayer, itemList = strtrim(entry):match("^([^:]+):(.*)$");

        if (rawPlayer and itemList ~= nil) then
            rawPlayer = strtrim(rawPlayer);
            itemList = strtrim(itemList);

            local isAlt = false;
            local isRecruit = false;
            local altBase = rawPlayer:match("^(.-)%*[aA][lL][tT]$") or rawPlayer:match("^(.-)%s*%([aA][lL][tT]%)$");
            if (altBase) then
                rawPlayer = strtrim(altBase);
                isAlt = true;
            end
            local recruitBase = rawPlayer:match("^(.-)%*[rR][eE][cC][rR][uU][iI][tT]$") or rawPlayer:match("^(.-)%s*%([rR][eE][cC][rR][uU][iI][tT]%)$");
            if (recruitBase) then
                rawPlayer = strtrim(recruitBase);
                isRecruit = true;
            end

            local playerName = normalizeName(rawPlayer);
            local Items = {};

            if (itemList ~= "") then
                for itemEntry in itemList:gmatch("[^,]+") do
                    local itemName, rolls = strtrim(itemEntry):match("^(.+)=%s*(%d+)$");

                    if (itemName and rolls) then
                        local count = math.min(tonumber(rolls) or 0, cap);
                        Items[normalizeItem(itemName)] = count;
                    end
                end
            end

            if (playerName ~= "" and (next(Items) or itemList == "")) then
                Parsed[playerName] = Items;
                if (isAlt) then
                    ParsedAlts[playerName] = true;
                elseif (isRecruit) then
                    ParsedRecruits[playerName] = true;
                end
            end
        end
    end

    self.ExtraRolls = Parsed;
    self.Alts = ParsedAlts;
    self.Recruits = ParsedRecruits;
    self.rawImportString = data;
    self:persist();

    return not GL:empty(Parsed);
end

---@return number
function RollingSR:countPlayers()
    local count = 0;
    for _ in pairs(self.ExtraRolls or {}) do
        count = count + 1;
    end
    return count;
end

---@return boolean
function RollingSR:hasData()
    return not GL:empty(self.ExtraRolls);
end

--- Does any guild player have this item in the imported string or SoftRes?
---
---@param itemLinkOrName string
---@return boolean
function RollingSR:tracksItem(itemLinkOrName)
    if (not self:hasData()) then
        return false;
    end

    local itemName = normalizeItem(tostring(itemLinkOrName or ""):match("%[(.-)%]") or itemLinkOrName);

    for _, Items in pairs(self.ExtraRolls) do
        if (Items[itemName] ~= nil) then
            return true;
        end
    end

    if (GL.SoftRes and GL.SoftRes:available() and GL.SoftRes.byItemLink) then
        for _, srName in pairs(GL.SoftRes:byItemLink(itemLinkOrName) or {}) do
            if (self:isGuildPlayer(srName)) then
                return true;
            end
        end
    end

    return false;
end

--- Guild players (Mains and Alts) are the ones present in the imported string
---
---@param playerName string
---@return boolean
function RollingSR:isGuildPlayer(playerName)
    return self.ExtraRolls[normalizeName(playerName)] ~= nil;
end

--- Check whether a guild player is flagged as an Alt
---
---@param playerName string
---@return boolean
function RollingSR:isAlt(playerName)
    return (self.Alts and self.Alts[normalizeName(playerName)]) == true;
end

--- Check whether a guild player is flagged as a Recruit on trial
---
---@param playerName string
---@return boolean
function RollingSR:isRecruit(playerName)
    return (self.Recruits and self.Recruits[normalizeName(playerName)]) == true;
end

--- Check whether a player is a Full Guild Member (not Alt or Recruit)
---
---@param playerName string
---@return boolean
function RollingSR:isMember(playerName)
    return self:isGuildPlayer(playerName) and not self:isAlt(playerName) and not self:isRecruit(playerName);
end

--- Check whether a player is a Guild Main (Member or Recruit, not Alt or Pug)
---
---@param playerName string
---@return boolean
function RollingSR:isMain(playerName)
    return self:isGuildPlayer(playerName) and not self:isAlt(playerName);
end

---@param playerName string
---@return boolean
function RollingSR:reservedCurrentItem(playerName)
    local CurrentRollOff = GL.RollOff.CurrentRollOff;
    local Items = self.ExtraRolls[normalizeName(playerName)];

    if (Items and Items[normalizeItem(CurrentRollOff.itemName)] ~= nil) then
        return true;
    end

    return GL.SoftRes:itemIDIsReservedByPlayer(CurrentRollOff.itemID, playerName);
end

--- Did at least one Full Guild Member reserve the current roll-off item?
---
---@return boolean
function RollingSR:anyMainReservedCurrentItem()
    local CurrentRollOff = GL.RollOff.CurrentRollOff;
    local normItem = normalizeItem(CurrentRollOff and CurrentRollOff.itemName or "");

    for name, Items in pairs(self.ExtraRolls or {}) do
        if (not self:isAlt(name) and not self:isRecruit(name) and Items[normItem] ~= nil) then
            return true;
        end
    end

    if (GL.SoftRes and GL.SoftRes:available() and CurrentRollOff and CurrentRollOff.itemID and GL.SoftRes.byItemID) then
        for _, srName in pairs(GL.SoftRes:byItemID(CurrentRollOff.itemID) or {}) do
            if (self:isMember(srName)) then
                return true;
            end
        end
    end

    return false;
end

--- Did at least one Pug reserve the current roll-off item?
---
---@return boolean
function RollingSR:anyPugReservedCurrentItem()
    if (not (GL.SoftRes and GL.SoftRes:available())) then
        return true;
    end

    local CurrentRollOff = GL.RollOff.CurrentRollOff;
    local Reservists = {};
    if (CurrentRollOff and CurrentRollOff.itemID and GL.SoftRes.byItemID) then
        Reservists = GL.SoftRes:byItemID(CurrentRollOff.itemID) or {};
    elseif (CurrentRollOff and CurrentRollOff.itemLink and GL.SoftRes.byItemLink) then
        Reservists = GL.SoftRes:byItemLink(CurrentRollOff.itemLink) or {};
    end

    for _, srName in pairs(Reservists) do
        if (not self:isGuildPlayer(srName)) then
            return true;
        end
    end

    return false;
end

--- Check whether any player in the raid group is a Pug (not in guild ExtraRolls)
---
---@return boolean
function RollingSR:anyPugInRaid()
    if (not IsInRaid or not IsInRaid()) then
        return false;
    end

    local numMembers = GetNumGroupMembers and GetNumGroupMembers() or 0;
    for i = 1, numMembers do
        local name = GetRaidRosterInfo and GetRaidRosterInfo(i);
        if (name and not self:isGuildPlayer(name)) then
            return true;
        end
    end

    return false;
end

--- Check whether Pugs are present (reserved the item, in raid, or test flag)
---
---@return boolean
function RollingSR:pugsPresent()
    if (self._testPugPresent ~= nil) then
        return self._testPugPresent;
    end

    if (self:anyPugReservedCurrentItem()) then
        return true;
    end

    if (self:anyPugInRaid()) then
        return true;
    end

    return false;
end

--- Alts can never win gear over Mains; they are only Phase 2 eligible if no Main reserved the item.
--- Recruits on trial are Phase 2 eligible with 0 bonus rolls (their Phase 1 roll stands).
---
---@param playerName string
---@return boolean
function RollingSR:isPhase2Eligible(playerName)
    if (not self:isGuildPlayer(playerName) or not self:reservedCurrentItem(playerName)) then
        return false;
    end

    if (self:isAlt(playerName) and self:anyMainReservedCurrentItem()) then
        return false;
    end

    return true;
end

---@param playerName string
---@param itemName string
---@return number
function RollingSR:getExtraRolls(playerName, itemName)
    if (self:isAlt(playerName) and not self.altsAccrueRolls) then
        return 0;
    end

    local Items = self.ExtraRolls[normalizeName(playerName)];

    if (not Items) then
        return 0;
    end

    local raw = Items[normalizeItem(itemName)] or 0;
    local cap = tonumber(self.maxExtraRolls) or 100;
    return math.min(raw, cap);
end

--- Phase 2 allows ExtraRolls bonus rolls (Phase 1 roll stands as a candidate to win)
---
---@param playerName string
---@param itemName string
---@return number
function RollingSR:allowedPhase2Rolls(playerName, itemName)
    return self:getExtraRolls(playerName, itemName);
end

---@return boolean
function RollingSR:isActive()
    return self.phase ~= PHASE_NONE;
end

---@return boolean
function RollingSR:isPhase1()
    return self.phase == PHASE_ONE;
end

---@return boolean
function RollingSR:isPhase2()
    return self.phase == PHASE_TWO;
end

--- Tie-breaks and Phase 2 only run on the initiator's end, clients already stopped
---
---@return boolean
function RollingSR:runsLocally()
    return self.phase == PHASE_TWO or (self.phase == PHASE_ONE and self.round > 0);
end

---@return nil
function RollingSR:beginPhase1()
    self:resetPhase();
    self.phase = PHASE_ONE;
end

--- Gate (and tag) an incoming roll based on the current phase's rules
---
---@param Roll table|string
---@return boolean
function RollingSR:acceptRoll(Roll)
    if (self.phase == PHASE_NONE) then
        return true;
    end

    local playerName = type(Roll) == "table" and Roll.player or Roll;
    local name = normalizeName(playerName);
    local used = self.RollCounts[name] or 0;
    local allowed = 1;

    if (self.phase == PHASE_ONE) then
        if (self.TiedPlayers) then
            if (not self.TiedPlayers[name]) then
                return false;
            end
        else
            if (GL.SoftRes:available() and not self:reservedCurrentItem(playerName)) then
                return false;
            end

            -- Alts participate in Phase 1 only when Pugs are present (or no Mains reserved the item)
            if (self:isAlt(playerName) and self:anyMainReservedCurrentItem() and not self:anyPugReservedCurrentItem()) then
                return false;
            end
        end
    elseif (self.phase == PHASE_TWO) then
        if (not self:isPhase2Eligible(playerName)) then
            return false;
        end

        allowed = self:allowedPhase2Rolls(playerName, GL.RollOff.CurrentRollOff.itemName);
    end

    if (used >= allowed) then
        return false;
    end

    self.RollCounts[name] = used + 1;

    if (type(Roll) == "table") then
        Roll.rsrPhase = self.phase;
        Roll.rsrRound = self.round;

        if (self.round > 0 and self.phase == PHASE_ONE) then
            Roll.classification = "TIE";
        end
    end

    return true;
end

--- All rolls sharing the highest amount among the rolls that pass the filter
---
---@param Rolls table
---@param filter function
---@return table
local function topRolls(Rolls, filter)
    local Top = {};
    local highest;

    for _, Roll in pairs(Rolls or {}) do
        if (filter(Roll)) then
            if (not highest or Roll.amount > highest) then
                highest = Roll.amount;
                Top = { Roll, };
            elseif (Roll.amount == highest) then
                tinsert(Top, Roll);
            end
        end
    end

    return Top;
end

---@param Rolls table
---@return string
local function playerList(Rolls)
    local Names = {};

    for _, Roll in pairs(Rolls) do
        tinsert(Names, Roll.player);
    end

    return table.concat(Names, ", ");
end

--- Called by RollOff:stop on the initiator's end.
--- Returns true when the roll-off continues (tie-break or Phase 2).
---
---@param CurrentRollOff table
---@return boolean
function RollingSR:handleStop(CurrentRollOff)
    if (self.phase == PHASE_ONE) then
        return self:evaluatePhase1(CurrentRollOff);
    end

    if (self.phase == PHASE_TWO) then
        self:finishPhase2(CurrentRollOff);
    end

    return false;
end

---@param CurrentRollOff table
---@return boolean
function RollingSR:evaluatePhase1(CurrentRollOff)
    local round = self.round;
    local softResLoaded = GL.SoftRes:available();

    -- Regular Phase 1: reservists only. Tie-break: only this round's rolls
    local Top = topRolls(CurrentRollOff.Rolls, function (Roll)
        if (Roll.rsrPhase ~= PHASE_ONE or Roll.rsrRound ~= round) then
            return false;
        end

        return round > 0 or not softResLoaded or self:reservedCurrentItem(Roll.player);
    end);

    if (#Top == 0) then
        -- Nobody rolled in the tie-break, keep waiting
        if (round > 0) then
            GL:sendChatMessage(("Rolling SR: still waiting for tie-break rolls from %s"):format(self:tiedPlayerList()), "RAID_WARNING");
            return true;
        end

        self:resetPhase();
        return false;
    end

    local pugInvolved = false;
    for _, Roll in pairs(Top) do
        if (not self:isGuildPlayer(Roll.player)) then
            pugInvolved = true;
            break;
        end
    end

    -- A tie only matters when a Pug is in it; guild-only ties go to Phase 2 either way
    if (#Top > 1 and pugInvolved) then
        self:startTiebreak(Top, CurrentRollOff);
        return true;
    end

    if (pugInvolved) then
        GL:sendChatMessage(
            ("Rolling SR: %s wins %s with a roll of %d (Phase 1)"):format(Top[1].player, CurrentRollOff.itemLink or "", Top[1].amount),
            "RAID_WARNING"
        );
        self:resetPhase();

        return false;
    end

    self:startPhase2(CurrentRollOff);

    return true;
end

---@return string
function RollingSR:tiedPlayerList()
    local Names = {};

    for name in pairs(self.TiedPlayers or {}) do
        tinsert(Names, GL:capitalize(name));
    end

    return table.concat(Names, ", ");
end

---@param Tied table
---@param CurrentRollOff table
---@return nil
function RollingSR:startTiebreak(Tied, CurrentRollOff)
    self.round = self.round + 1;
    self.RollCounts = {};
    self.TiedPlayers = {};

    for _, Roll in pairs(Tied) do
        self.TiedPlayers[normalizeName(Roll.player)] = true;
    end

    GL:sendChatMessage(
        ("Rolling SR: tie at %d on %s! %s, /roll again"):format(Tied[1].amount, CurrentRollOff.itemLink or "", playerList(Tied)),
        "RAID_WARNING"
    );

    GL.RollOff:listenForRolls();
end

---@param CurrentRollOff table
---@return nil
function RollingSR:startPhase2(CurrentRollOff)
    self.phase = PHASE_TWO;
    self.round = 0;
    self.TiedPlayers = nil;
    self.RollCounts = {};

    local itemName = CurrentRollOff.itemName or "";

    GL:sendChatMessage(
        ("Rolling SR Phase 2: guild players, roll your bonus rolls on %s! (Phase 1 rolls stand)"):format(CurrentRollOff.itemLink or itemName),
        "RAID_WARNING"
    );

    for name in pairs(self.ExtraRolls) do
        if (self:isPhase2Eligible(name)) then
            local extra = self:getExtraRolls(name, itemName);

            if (extra > 0) then
                GL:sendChatMessage(
                    ("%s: %d bonus roll(s) in Phase 2 (Phase 1 rolls stand!)"):format(GL:capitalize(name), extra),
                    "GROUP"
                );
            else
                GL:sendChatMessage(
                    ("%s: 0 bonus rolls (Phase 1 roll stands)"):format(GL:capitalize(name)),
                    "GROUP"
                );
            end
        end
    end

    GL.RollOff:listenForRolls();
end

--- Drop ineligible and tie-break rolls, then announce the winner
---
---@param CurrentRollOff table
---@return nil
function RollingSR:finishPhase2(CurrentRollOff)
    self:resetPhase();

    local Filtered = {};
    for _, Roll in pairs(CurrentRollOff.Rolls or {}) do
        local isTieBreakRoll = (Roll.rsrPhase == PHASE_ONE and (Roll.rsrRound or 0) > 0);
        if (not isTieBreakRoll and self:isPhase2Eligible(Roll.player)) then
            tinsert(Filtered, Roll);
        end
    end
    CurrentRollOff.Rolls = Filtered;

    local Top = topRolls(Filtered, function () return true; end);

    if (#Top == 1) then
        GL:sendChatMessage(
            ("Rolling SR: %s wins %s with a roll of %d"):format(Top[1].player, CurrentRollOff.itemLink or "", Top[1].amount),
            "RAID_WARNING"
        );
    elseif (#Top > 1) then
        GL:sendChatMessage(
            ("Rolling SR: tie at %d on %s between %s"):format(Top[1].amount, CurrentRollOff.itemLink or "", playerList(Top)),
            "RAID_WARNING"
        );
    end

    GL.RollOff:refreshRollsTable();
end

---@return nil
function RollingSR:resetPhase()
    self.phase = PHASE_NONE;
    self.round = 0;
    self.TiedPlayers = nil;
    self.RollCounts = {};
end

--- Persist extra rolls into saved variables
---
---@return nil
function RollingSR:persist()
    GL.DB:set("RollingSR.ExtraRolls", self.ExtraRolls);
    GL.DB:set("RollingSR.Alts", self.Alts);
    GL.DB:set("RollingSR.Recruits", self.Recruits);
    GL.DB:set("RollingSR.AwardedItems", self.AwardedItems);
    GL.DB:set("RollingSR.maxExtraRolls", self.maxExtraRolls);
    GL.DB:set("RollingSR.altsAccrueRolls", self.altsAccrueRolls);
    if (self.rawImportString) then
        GL.DB:set("RollingSR.rawImportString", self.rawImportString);
    end
end

--- Reset extra rolls to 0 for a player who won the item and record in AwardedItems
---
---@param winner string
---@param itemLinkOrID string|number
---@return nil
function RollingSR:onItemAwarded(winner, itemLinkOrID)
    local name = normalizeName(winner);

    if (not self.ExtraRolls[name]) then
        return;
    end

    local rawItemName = GL:getItemNameFromLink(itemLinkOrID) or tostring(itemLinkOrID or "");
    rawItemName = strtrim(tostring(rawItemName):match("%[(.-)%]") or tostring(rawItemName));
    local itemName = normalizeItem(rawItemName);

    local hadItem = (self.ExtraRolls[name][itemName] ~= nil);
    if (hadItem) then
        self.ExtraRolls[name][itemName] = 0;
    end

    if (hadItem or (GL.SoftRes and GL.SoftRes:available())) then
        self.AwardedItems = self.AwardedItems or {};
        local exists = false;
        for _, entry in ipairs(self.AwardedItems) do
            if (normalizeName(entry.player) == name and normalizeItem(entry.item) == itemName) then
                exists = true;
                break;
            end
        end
        if (not exists and rawItemName ~= "") then
            tinsert(self.AwardedItems, {
                player = GL:capitalize(name),
                item = rawItemName,
            });
        end
    end

    self:persist();

    if (hadItem) then
        local itemDisplay = tostring(itemLinkOrID or itemName);
        if (type(itemLinkOrID) == "number" and GetItemInfo) then
            local _, link = GetItemInfo(itemLinkOrID);
            if (link) then
                itemDisplay = link;
            end
        end

        GL:success(("[Rolling SR] %s awarded to %s. Extra rolls reset to 0. (Type /rsr won after raid to export won items)"):format(
            itemDisplay,
            GL:capitalize(winner)
        ));
    end
end

--- Build the compact won-items export string for Google Sheets
--- Format: Player1:Item1;Player2:Item2;
---
---@return string
function RollingSR:getAwardExportString()
    local Parts = {};
    for _, entry in ipairs(self.AwardedItems or {}) do
        if (entry.player and entry.item) then
            tinsert(Parts, ("%s:%s"):format(entry.player, entry.item));
        end
    end
    if (#Parts == 0) then
        return "";
    end
    return table.concat(Parts, ";") .. ";";
end

--- Display and open a copyable dialog with the won-items export string
---
---@return string
function RollingSR:showAwardExport()
    local exportStr = self:getAwardExportString();
    if (exportStr == "") then
        GL:warning("[Rolling SR] No won items recorded in this session yet.");
        return "";
    end

    GL:success("[Rolling SR] Won Items Export String (paste into Google Sheet 'Rolling SR > Import Won Items String'):");
    GL:message("  " .. exportStr);

    if (GL.Interface and GL.Interface.Dialogs and GL.Interface.Dialogs.HyperlinkDialog and GL.Interface.Dialogs.HyperlinkDialog.open) then
        GL.Interface.Dialogs.HyperlinkDialog:open({
            description = "Copy this won-items export string and paste it into your Google Sheet via 'Rolling SR > Import Won Items String' (or into Addon_Export!A3):",
            hyperlink = exportStr,
        });
    end

    return exportStr;
end

---@return nil
function RollingSR:clear()
    self.ExtraRolls = {};
    self.Alts = {};
    self.Recruits = {};
    self.AwardedItems = {};
    self.rawImportString = "";
    self:resetPhase();
    self:persist();
end

--- Format live status text for the Master Looter UI
---
---@param itemLinkOrName string
---@return string
function RollingSR:getStatusText(itemLinkOrName)
    if (not self:isActive()) then
        return "";
    end

    if (self.phase == PHASE_ONE) then
        if (self.round > 0) then
            local tiedTotal = 0;
            local tiedRolled = 0;
            for name in pairs(self.TiedPlayers or {}) do
                tiedTotal = tiedTotal + 1;
                if ((self.RollCounts[name] or 0) > 0) then
                    tiedRolled = tiedRolled + 1;
                end
            end
            return ("|cFFFFCC00Tie-Break: %d/%d rolled|r"):format(tiedRolled, tiedTotal);
        else
            local reservists = {};
            local totalReservists = 0;
            if (GL.SoftRes and GL.SoftRes:available()) then
                for _, name in pairs(GL.SoftRes:byItemLink(itemLinkOrName) or {}) do
                    local n = normalizeName(name);
                    if (not reservists[n]) then
                        reservists[n] = true;
                        totalReservists = totalReservists + 1;
                    end
                end
            end

            if (totalReservists > 0) then
                local rolledCount = 0;
                for name in pairs(reservists) do
                    if ((self.RollCounts[name] or 0) > 0) then
                        rolledCount = rolledCount + 1;
                    end
                end
                return ("|cFF00FF00Phase 1: %d/%d rolled|r"):format(rolledCount, totalReservists);
            end

            return "|cFF00FF00Phase 1: In Progress|r";
        end
    elseif (self.phase == PHASE_TWO) then
        local totalAllowed = 0;
        local totalCast = 0;
        local normalizedItem = normalizeItem(itemLinkOrName);

        for name, items in pairs(self.ExtraRolls) do
            if (self:isPhase2Eligible(name) and items[normalizedItem] ~= nil) then
                local allowed = self:allowedPhase2Rolls(name, itemLinkOrName);
                totalAllowed = totalAllowed + allowed;
                local used = self.RollCounts[name] or 0;
                totalCast = totalCast + math.min(used, allowed);
            end
        end

        if (totalAllowed > 0) then
            if (totalCast >= totalAllowed) then
                return ("|cFF00BFFFPhase 2: %d/%d (All in!)|r"):format(totalCast, totalAllowed);
            end
            return ("|cFF00BFFFPhase 2: %d/%d rolls|r"):format(totalCast, totalAllowed);
        end

        return "|cFF00BFFFPhase 2: In Progress|r";
    end

    return "";
end

--- Broadcast the weekly extra rolls data over addon comms to group or guild
---
---@param channel? string "GROUP" or "GUILD"
---@return nil
function RollingSR:broadcast(channel)
    if (not self:hasData()) then
        GL:warning("[Rolling SR] No extra rolls data to broadcast. Import data first.");
        return;
    end

    if (not GL.CommMessage or not GL.CommMessage.new) then
        return;
    end

    local payload = self.rawImportString;
    if (GL:empty(payload)) then
        local Entries = {};
        for name, items in pairs(self.ExtraRolls) do
            local ItemPairs = {};
            for item, rolls in pairs(items) do
                tinsert(ItemPairs, ("%s=%d"):format(item, rolls));
            end
            local tag = self:isAlt(name) and "*alt" or "";
            tinsert(Entries, ("%s%s:%s"):format(GL:capitalize(name), tag, table.concat(ItemPairs, ",")));
        end
        payload = table.concat(Entries, ";") .. ";";
    end

    local targetChannel = channel;
    if (not targetChannel or targetChannel == "") then
        targetChannel = (GL.User and GL.User.isInGroup) and "GROUP" or "GUILD";
    end

    GL.CommMessage.new({
        action = GL.Data.Constants.Comm.Actions.broadcastRollingSRData,
        content = payload,
        channel = targetChannel,
    }):send();

    GL:success(("[Rolling SR] Broadcasted extra rolls for %d players to %s."):format(self:countPlayers(), targetChannel));
end

--- Receive broadcasted extra rolls data from another officer/ML
---
---@param Message CommMessage
---@return nil
function RollingSR:receiveBroadcast(Message)
    if (Message.Sender.isSelf) then
        return;
    end

    if (not Message.content or Message.content == "") then
        return;
    end

    local success = self:parseImportString(Message.content);
    if (success) then
        GL:success(("[Rolling SR] Synced extra rolls from %s (%d players updated)."):format(Message.Sender.name or "officer", self:countPlayers()));
    end
end

--- Reply to !rsr or !rolls whispers with the sender's bonus roll counts
---
---@param message string
---@param sender string
---@return nil
function RollingSR:handleWhisperCommand(message, sender)
    local msg = strlower(strtrim(tostring(message or "")));
    if (msg ~= "!rsr" and msg ~= "!rolls" and msg ~= "!rollingsr") then
        return;
    end

    local name = normalizeName(sender);
    local Items = self.ExtraRolls[name];

    if (not Items) then
        GL:sendChatMessage(
            "[Rolling SR] No stored bonus rolls found for your character.",
            "WHISPER", nil, sender
        );
        return;
    end

    if (self:isRecruit(name)) then
        GL:sendChatMessage(
            "[Rolling SR] Your character is registered as a Guild Recruit (+0 bonus rolls during 2-week trial; Phase 1 roll stands in Phase 2; soft reserves accrue bonus rolls for when trial ends).",
            "WHISPER", nil, sender
        );
        return;
    end

    if (self:isAlt(name)) then
        if (not self.altsAccrueRolls or GL:empty(Items)) then
            GL:sendChatMessage(
                "[Rolling SR] Your character is registered as a Guild Alt (+0 bonus rolls; eligible in Phase 1 vs Pugs).",
                "WHISPER", nil, sender
            );
            return;
        end

        local AltParts = {};
        for item in pairs(Items) do
            local rolls = self:getExtraRolls(name, item);
            tinsert(AltParts, ("%s (Alt +%d bonus roll(s) in Phase 2 if no Main reserved; Phase 1 roll stands)"):format(item, rolls));
        end
        table.sort(AltParts);
        GL:sendChatMessage(
            ("[Rolling SR] Your Alt reserves: %s"):format(table.concat(AltParts, ", ")),
            "WHISPER", nil, sender
        );
        return;
    end

    if (GL:empty(Items)) then
        GL:sendChatMessage(
            "[Rolling SR] Registered as Guild Main (+0 stored bonus rolls).",
            "WHISPER", nil, sender
        );
        return;
    end

    local Parts = {};
    for item in pairs(Items) do
        local rolls = self:getExtraRolls(name, item);
        tinsert(Parts, ("%s (+%d bonus roll(s) in Phase 2; Phase 1 roll stands)"):format(item, rolls));
    end
    table.sort(Parts);

    GL:sendChatMessage(
        ("[Rolling SR] Your reserves: %s"):format(table.concat(Parts, ", ")),
        "WHISPER", nil, sender
    );
end

--- Print stored bonus rolls for one player or all loaded players
---
---@param targetName? string
---@return nil
function RollingSR:printPlayerRolls(targetName)
    if (not self:hasData()) then
        GL:warning("[Rolling SR] No extra rolls data loaded.");
        return;
    end

    if (targetName and targetName ~= "") then
        local key = normalizeName(targetName);
        local Items = self.ExtraRolls[key];
        if (not Items) then
            GL:warning(("[Rolling SR] %s is not in the guild bonus roll table (treated as Pug)."):format(GL:capitalize(key)));
            return;
        end
        local roleTag = self:isAlt(key) and " [Alt]" or (self:isRecruit(key) and " [Recruit]" or "");
        local Parts = {};
        for item in pairs(Items) do
            tinsert(Parts, ("%s (+%d)"):format(item, self:getExtraRolls(key, item)));
        end
        table.sort(Parts);
        local summary = #Parts > 0 and table.concat(Parts, ", ") or "(no active items)";
        GL:message(("[Rolling SR] %s%s: %s"):format(GL:capitalize(key), roleTag, summary));
        return;
    end

    local Names = {};
    for name in pairs(self.ExtraRolls) do
        tinsert(Names, name);
    end
    table.sort(Names);

    local altMode = self.altsAccrueRolls and "ON" or "OFF";
    GL:message(("[Rolling SR] Loaded players (%d, max cap: %d, alt bonus rolls: %s):"):format(#Names, self.maxExtraRolls or 100, altMode));
    for _, name in ipairs(Names) do
        local roleTag = self:isAlt(name) and " [Alt]" or (self:isRecruit(name) and " [Recruit]" or "");
        local Parts = {};
        for item in pairs(self.ExtraRolls[name]) do
            tinsert(Parts, ("%s (+%d)"):format(item, self:getExtraRolls(name, item)));
        end
        table.sort(Parts);
        local summary = #Parts > 0 and table.concat(Parts, ", ") or "(no active items)";
        GL:message(("  %s%s: %s"):format(GL:capitalize(name), roleTag, summary));
    end
end

--- Handle "/rsr <args>" (or "/gl rsr <args>") slash command
---
---@param argumentString string
---@return nil
function RollingSR:handleCommand(argumentString)
    local arg = strtrim(argumentString or "");

    if (arg == "") then
        local altMode = self.altsAccrueRolls and "ON" or "OFF";
        GL:message(("[Rolling SR] Tracking %d guild players (max cap: %d, alt rolls: %s)."):format(self:countPlayers(), self.maxExtraRolls or 100, altMode));
        GL:message("Commands (all 1-2 words):");
        GL:message("  /rsr <string>    - Import Addon_Export string & auto-broadcast");
        GL:message("  /rsr list        - List all loaded guild Mains, Alts & bonus rolls");
        GL:message("  /rsr <player>    - Check bonus rolls for a player (e.g. /rsr Thrall)");
        GL:message("  /rsr won         - Export won items string for Google Sheets");
        GL:message("  /rsr sync        - Broadcast data to raid or guild");
        GL:message("  /rsr max <num>   - View or set max accumulated rolls cap (default 100)");
        GL:message("  /rsr altrolls    - Toggle whether Alts can accrue/spend bonus rolls");
        GL:message("  /rsr test        - Enable solo test mode (no sheet needed!)");
        GL:message("  /rsr sim         - Simulate rolls (/rsr tie, /rsr simpug, /rsr simalt, /rsr simwon)");
        GL:message("  /rsr clear       - Clear all Rolling SR data");
        return;
    end

    local lowerArg = strlower(arg);

    if (lowerArg == "list" or lowerArg == "status") then
        self:printPlayerRolls();
        return;
    end

    if (lowerArg == "won" or lowerArg == "export" or lowerArg == "awards") then
        self:showAwardExport();
        return;
    end

    if (lowerArg == "clearwon") then
        self.AwardedItems = {};
        self:persist();
        GL:success("[Rolling SR] Cleared won items export log.");
        return;
    end

    local maxVal = lowerArg:match("^max%s+(%d+)$") or lowerArg:match("^cap%s+(%d+)$");
    if (maxVal) then
        self.maxExtraRolls = tonumber(maxVal) or 100;
        self:persist();
        GL:success(("[Rolling SR] Max accumulated extra rolls cap set to %d."):format(self.maxExtraRolls));
        return;
    elseif (lowerArg == "max" or lowerArg == "cap") then
        GL:message(("[Rolling SR] Current max accumulated extra rolls cap: %d (change with /rsr max <number>)."):format(self.maxExtraRolls or 100));
        return;
    end

    local altRollsArg = lowerArg:match("^altrolls?%s*(.*)$");
    if (altRollsArg ~= nil) then
        altRollsArg = strtrim(altRollsArg);
        if (altRollsArg == "on" or altRollsArg == "true" or altRollsArg == "1") then
            self.altsAccrueRolls = true;
        elseif (altRollsArg == "off" or altRollsArg == "false" or altRollsArg == "0") then
            self.altsAccrueRolls = false;
        else
            self.altsAccrueRolls = not self.altsAccrueRolls;
        end
        self:persist();
        local stateStr = self.altsAccrueRolls and "ENABLED (Alts use accumulated bonus rolls when no Main reserved)" or "DISABLED (Alts always have 0 bonus rolls)";
        GL:success(("[Rolling SR] Alt bonus roll accumulation is now %s."):format(stateStr));
        return;
    end

    local checkTarget = arg:match("^[cC][hH][eE][cC][kK]%s+(.+)$");
    if (checkTarget) then
        self:printPlayerRolls(strtrim(checkTarget));
        return;
    end

    if (lowerArg == "test" or lowerArg == "demo") then
        self:enableTestMode();
        return;
    end

    if (lowerArg == "sim" or lowerArg == "simulate") then
        self:simulateRolls(false);
        return;
    end

    if (lowerArg == "tie" or lowerArg == "sim tie" or lowerArg == "simulate tie") then
        self:simulateRolls("tie");
        return;
    end

    if (lowerArg == "simpug" or lowerArg == "sim pug" or lowerArg == "simulate pug") then
        self:simulateRolls("pug");
        return;
    end

    if (lowerArg == "simalt" or lowerArg == "sim alt" or lowerArg == "simulate alt") then
        self:simulateRolls("alt");
        return;
    end

    if (lowerArg == "simwon" or lowerArg == "sim won" or lowerArg == "simaward" or lowerArg == "sim award") then
        self:simulateAward();
        return;
    end

    if (lowerArg == "sync" or lowerArg == "broadcast") then
        self:broadcast();
        return;
    end

    if (lowerArg == "guild" or lowerArg == "broadcast guild" or lowerArg == "sync guild") then
        self:broadcast("GUILD");
        return;
    end

    if (lowerArg == "raid" or lowerArg == "group" or lowerArg == "broadcast group" or lowerArg == "broadcast raid" or lowerArg == "sync raid") then
        self:broadcast("GROUP");
        return;
    end

    if (lowerArg == "clear") then
        self:clear();
        GL:success("[Rolling SR] Cleared all extra rolls data.");
        return;
    end

    -- Single word without ":" or "=" is a player name lookup (e.g. "/rsr Thrall")
    if (not arg:find("[:=;]") and not arg:find("%s")) then
        self:printPlayerRolls(arg);
        return;
    end

    -- Otherwise, treat argumentString as the import string
    local success = self:parseImportString(arg);
    if (success) then
        GL:success(("[Rolling SR] Successfully imported bonus rolls for %d players!"):format(self:countPlayers()));
        self:broadcast();
    else
        GL:warning("[Rolling SR] Failed to import. Expected format: Player:Item=Rolls,Item=Rolls;");
    end
end

--- Enable solo in-game test mode without needing to update Google Sheets
---
---@return nil
function RollingSR:enableTestMode()
    local playerName = GL.User and GL.User.name or "Tester";
    if (playerName == "") then
        playerName = UnitName and UnitName("player") or "Tester";
    end

    -- 1. Setup mock Soft Reserves in Gargul for two Vanilla Molten Core items
    --    (present in all WoW clients including Vanilla / Classic Era / WoW Forever 16001):
    --    18832 (Brutality Blade): Main + Alt + Pug
    --    18820 (Talisman of Ephemeral Power): Alt + Pug only (no Mains)
    local testItem = "Brutality Blade";
    local testItemID = 18832;
    local altItem = "Talisman of Ephemeral Power";
    local altItemID = 18820;

    if (GL.hydrateItemLink) then
        GL:hydrateItemLink(testItemID);
        GL:hydrateItemLink(altItemID);
    end

    local csvData = table.concat({
        "Name,Class,ItemId,ItemName,Note,Plus",
        ("%s,Warrior,%d,%s,,0"):format(playerName, testItemID, testItem),
        ("Guildmate,Paladin,%d,%s,,0"):format(testItemID, testItem),
        ("Guildalt,Hunter,%d,%s,,0"):format(testItemID, testItem),
        ("Pugman,Rogue,%d,%s,,0"):format(testItemID, testItem),
        ("Guildalt,Hunter,%d,%s,,0"):format(altItemID, altItem),
        ("Pugman,Rogue,%d,%s,,0"):format(altItemID, altItem),
    }, "\n");

    if (GL.SoftRes and GL.SoftRes.importCSVData) then
        GL.SoftRes:importCSVData(csvData, false);
    end

    -- 2. Setup mock Rolling SR bonus rolls
    local rsrString = ("%s:%s=2;Guildmate:%s=1;Guildalt*alt:%s=1,%s=2;"):format(
        playerName, testItem, testItem, testItem, altItem
    );
    self:parseImportString(rsrString);

    GL:success("=================================================");
    GL:success("[Rolling SR] TEST MODE ENABLED (No Sheet Needed!)");
    GL:message(("1) [%s] (%d) — Mains + Alt + Pug:"):format(testItem, testItemID));
    GL:message(("   • %s (You - Main): +2 bonus rolls | Guildmate (Main): +1 | Guildalt (Alt) | Pugman (Pug)"):format(GL:capitalize(playerName)));
    GL:message(("2) [%s] (%d) — Alt + Pug Only (no Mains):"):format(altItem, altItemID));
    GL:message("   • Guildalt (Alt): +0 default, or +2 when '/rsr altrolls' is ON | Pugman (Pug)");
    GL:message("Test commands during '/gl ro 18832' or '/gl ro 18820':");
    GL:message("  • /rsr sim      - Standard roll simulation (Phase 1, Tie-Break, or Phase 2)");
    GL:message("  • /rsr simpug   - Simulate Pug winning Phase 1 outright (99)");
    GL:message("  • /rsr simalt   - Simulate Alt winning Phase 1 over Pug (97)");
    GL:message("  • /rsr tie      - Simulate Phase 1 tie (95) to test tie-breaker");
    GL:message("  • /rsr simwon   - Simulate awarding the item to test '/rsr won' export");
    GL:message("  • /rsr altrolls - Toggle Alt bonus roll accumulation ON/OFF");
    GL:message("  • /rsr clear    - Clean up test data when finished");
    GL:success("=================================================");
end

--- Simulate an item award during test mode so /rsr won can be tested without a boss corpse
---
---@return nil
function RollingSR:simulateAward()
    local winner = "Guildmate";
    local itemLinkOrName = "Brutality Blade";

    if (GL.RollOff and GL.RollOff.CurrentRollOff) then
        local ro = GL.RollOff.CurrentRollOff;
        if (ro.itemLink or ro.itemName) then
            itemLinkOrName = ro.itemLink or ro.itemName;
        end
        local Top = topRolls(ro.Rolls or {}, function (Roll)
            return self:isGuildPlayer(Roll.player);
        end);
        if (#Top > 0 and Top[1].player) then
            winner = Top[1].player;
        end
    end

    self:onItemAwarded(winner, itemLinkOrName);
end

--- Simulate rolls from other reservists during a test roll-off
---
---@param mode? boolean|string
---@return nil
function RollingSR:simulateRolls(mode)
    if (not GL.RollOff or not GL.RollOff.inProgress) then
        GL:warning("[Rolling SR Sim] No roll-off is currently in progress. Start one with /gl ro 18832 or /gl ro 18820");
        return;
    end

    if (not self:isActive()) then
        GL:warning("[Rolling SR Sim] Current item is not tracked by Rolling SR.");
        return;
    end

    local isTie = (mode == true or mode == "tie");
    local isPugWin = (mode == "pug");
    local isAltWin = (mode == "alt");

    if (self.phase == PHASE_ONE) then
        if (self.round == 0) then
            if (isTie) then
                GL.RollOff:processRoll("Pugman rolls 95 (1-100)");
                if (self:anyMainReservedCurrentItem()) then
                    GL.RollOff:processRoll("Guildmate rolls 95 (1-100)");
                    GL:success("[Rolling SR Sim] Simulated Phase 1 tie: Pugman (95), Guildmate (95). Click 'Stop Phase 1' to test tie-break!");
                else
                    GL.RollOff:processRoll("Guildalt rolls 95 (1-100)");
                    GL:success("[Rolling SR Sim] Simulated Phase 1 tie: Pugman (95), Guildalt (95). Click 'Stop Phase 1' to test tie-break!");
                end
            elseif (isPugWin) then
                GL.RollOff:processRoll("Pugman rolls 99 (1-100)");
                GL.RollOff:processRoll("Guildalt rolls 55 (1-100)");
                if (self:anyMainReservedCurrentItem()) then
                    GL.RollOff:processRoll("Guildmate rolls 42 (1-100)");
                end
                GL:success("[Rolling SR Sim] Simulated Pug high roll: Pugman (99). Click 'Stop Phase 1' to see Pug win Phase 1 outright!");
            elseif (isAltWin) then
                GL.RollOff:processRoll("Pugman rolls 80 (1-100)");
                GL.RollOff:processRoll("Guildalt rolls 97 (1-100)");
                if (self:anyMainReservedCurrentItem()) then
                    GL.RollOff:processRoll("Guildmate rolls 45 (1-100)");
                end
                GL:success("[Rolling SR Sim] Simulated Alt high roll: Guildalt (97) vs Pugman (80). Click 'Stop Phase 1' to trigger Phase 2!");
            else
                GL.RollOff:processRoll("Pugman rolls 72 (1-100)");
                GL.RollOff:processRoll("Guildalt rolls 88 (1-100)");
                if (self:anyMainReservedCurrentItem()) then
                    GL.RollOff:processRoll("Guildmate rolls 85 (1-100)");
                    GL:success("[Rolling SR Sim] Simulated Phase 1 rolls: Pugman (72), Guildalt (88), Guildmate (85).");
                else
                    GL:success("[Rolling SR Sim] Simulated Phase 1 rolls: Pugman (72), Guildalt (88).");
                end
            end
        else
            -- In tie-break round
            if (self.TiedPlayers and self.TiedPlayers["pugman"]) then
                GL.RollOff:processRoll("Pugman rolls 68 (1-100)");
            end
            if (self.TiedPlayers and self.TiedPlayers["guildmate"]) then
                GL.RollOff:processRoll("Guildmate rolls 89 (1-100)");
            end
            if (self.TiedPlayers and self.TiedPlayers["guildalt"]) then
                GL.RollOff:processRoll("Guildalt rolls 89 (1-100)");
            end
            GL:success("[Rolling SR Sim] Simulated tie-break rolls!");
        end
    elseif (self.phase == PHASE_TWO) then
        if (self:anyMainReservedCurrentItem()) then
            GL.RollOff:processRoll("Guildmate rolls 94 (1-100)");
            GL:success("[Rolling SR Sim] Simulated Phase 2 bonus roll for Guildmate (94).");
        else
            GL.RollOff:processRoll("Guildalt rolls 91 (1-100)");
            GL:success("[Rolling SR Sim] Simulated Phase 2 roll for Guildalt (91).");
        end
    end

    if (GL.MasterLooterUI and GL.MasterLooterUI.updateWidgets) then
        GL.MasterLooterUI:updateWidgets();
    end
    if (GL.RollOff and GL.RollOff.refreshRollsTable) then
        GL.RollOff:refreshRollsTable();
    end
end
