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
    -- Normalize curly/typographic quotes to standard apostrophe
    s = s:gsub("[\226\128\153\226\128\152`'’‘]", "'");
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

    GL.Events:register("RollingSRRollOffStarted", "GL.ROLLOFF_STARTED", function ()
        local currentItem = GL.RollOff.CurrentRollOff.itemName or GL.RollOff.CurrentRollOff.itemLink;
        if (self:tracksItem(currentItem)) then
            self:beginPhase1();
        else
            self:resetPhase();
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

    self._initialized = true;
end

--- Parse "Player:Item=Rolls,Item=Rolls;Player:Item=Rolls;" into ExtraRolls
---
---@param data string
---@return boolean
function RollingSR:parseImportString(data)
    if (GL:empty(data)) then
        return false;
    end

    local Parsed = {};

    for entry in data:gmatch("[^;]+") do
        local playerName, itemList = strtrim(entry):match("^([^:]+):(.+)$");

        if (playerName and itemList) then
            local Items = {};

            for itemEntry in itemList:gmatch("[^,]+") do
                local itemName, rolls = strtrim(itemEntry):match("^(.+)=%s*(%d+)$");

                if (itemName and rolls) then
                    Items[normalizeItem(itemName)] = tonumber(rolls) or 0;
                end
            end

            if (next(Items)) then
                Parsed[normalizeName(strtrim(playerName))] = Items;
            end
        end
    end

    self.ExtraRolls = Parsed;
    self:persist();

    return not GL:empty(Parsed);
end

---@return boolean
function RollingSR:hasData()
    return not GL:empty(self.ExtraRolls);
end

--- Does any guild player have this item in the imported string?
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

    return false;
end

--- Guild players (Members/Recruits) are the ones present in the imported string
---
---@param playerName string
---@return boolean
function RollingSR:isGuildPlayer(playerName)
    return self.ExtraRolls[normalizeName(playerName)] ~= nil;
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

---@param playerName string
---@return boolean
function RollingSR:isPhase2Eligible(playerName)
    return self:isGuildPlayer(playerName) and self:reservedCurrentItem(playerName);
end

---@param playerName string
---@param itemName string
---@return number
function RollingSR:getExtraRolls(playerName, itemName)
    local Items = self.ExtraRolls[normalizeName(playerName)];

    if (not Items) then
        return 0;
    end

    return Items[normalizeItem(itemName)] or 0;
end

--- Phase 2 allows 1 + ExtraRolls rolls
---
---@param playerName string
---@param itemName string
---@return number
function RollingSR:allowedPhase2Rolls(playerName, itemName)
    return 1 + self:getExtraRolls(playerName, itemName);
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
        ("Rolling SR Phase 2: guild reservists, /roll on %s!"):format(CurrentRollOff.itemLink or itemName),
        "RAID_WARNING"
    );

    for name in pairs(self.ExtraRolls) do
        if (self:isPhase2Eligible(name)) then
            local extra = self:getExtraRolls(name, itemName);

            GL:sendChatMessage(
                ("%s: %d roll(s) (%d extra)"):format(GL:capitalize(name), 1 + extra, extra),
                "GROUP"
            );
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
end

--- Reset extra rolls to 0 for a player who won the item
---
---@param winner string
---@param itemLinkOrID string|number
---@return nil
function RollingSR:onItemAwarded(winner, itemLinkOrID)
    local name = normalizeName(winner);

    if (not self.ExtraRolls[name]) then
        return;
    end

    local itemName = normalizeItem(GL:getItemNameFromLink(itemLinkOrID) or itemLinkOrID);

    if (self.ExtraRolls[name][itemName]) then
        self.ExtraRolls[name][itemName] = 0;
        self:persist();
        GL:debug(("Rolling SR: Reset extra rolls for %s on %s"):format(winner, itemName));
    end
end

---@return nil
function RollingSR:clear()
    self.ExtraRolls = {};
    self:resetPhase();
    self:persist();
end
