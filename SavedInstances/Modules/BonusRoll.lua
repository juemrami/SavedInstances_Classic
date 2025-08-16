---@class SavedInstances
local SI, L = unpack((select(2, ...)))
if SI.Enum.Expansion.Current < SI.Enum.Expansion.Mists then return end

---@class BonusRollsModule: AceModule, AceEvent-3.0
local Module = SI:NewModule('BonusRolls', 'AceEvent-3.0')

local BonusFrame -- Frame attached to BonusRollFrame
local MAX_BONUS_ROLL_RECORD_LIMIT = 25 -- the max cap of bonus roll records
local BONUS_ROLL_REQUIRED_CURRENCY = BONUS_ROLL_REQUIRED_CURRENCY -- bonus roll currency of current expansion

-- Lua functions
local tostring, ipairs, time, pairs, strsplit = tostring, ipairs, time, pairs, strsplit
local tonumber, tinsert, sort, select = tonumber, tinsert, sort, select
local _G = _G

-- WoW API / Variables
local CreateFrame = CreateFrame
local GetBonusRollEncounterJournalLinkDifficulty = GetBonusRollEncounterJournalLinkDifficulty
local GetDifficultyInfo = GetDifficultyInfo
local GetInstanceInfo = GetInstanceInfo
local GetItemInfoInstant = GetItemInfoInstant
local GetRealZoneText = GetRealZoneText
local GetSubZoneText = GetSubZoneText
local DifficultyUtil_ID_DungeonChallenge = DifficultyUtil.ID.DungeonChallenge

local function BonusRollShow()
  local t = SI.db.Toons[SI.thisToon]
  local BonusRollFrame = _G.BonusRollFrame
  if not t or not BonusRollFrame then return end
  local bonus = Module:GetCharacterWeeklyRollCount(SI.thisToon, BonusRollFrame.currencyID)
  if not bonus or not SI.db.Tooltip.AugmentBonus then
    if BonusFrame then BonusFrame:Hide() end
    return
  end
  if not BonusFrame then
    BonusFrame = CreateFrame("Button", "SavedInstancesBonusRollFrame", BonusRollFrame, "SpellBookSkillLineTabTemplate")
    BonusFrame:SetPoint("LEFT", BonusRollFrame, "RIGHT", 0, 8)
    BonusFrame.text = BonusFrame:CreateFontString(nil, "OVERLAY","GameFontNormal")
    BonusFrame.text:SetPoint("CENTER")
    BonusFrame:SetScript("OnEnter", function()
      SI.hoverTooltip.ShowBonusTooltip(nil, { SI.thisToon, BonusFrame })
    end)
    BonusFrame:SetScript("OnLeave", function()
      if SI.indicatortip then
        SI.indicatortip:Hide()
      end
    end)
    BonusFrame:SetScript("OnClick", nil)
    SI:SkinFrame(BonusFrame, BonusFrame:GetName())
  end
  BonusFrame.text:SetText((bonus > 0 and "+" or "")..bonus)
  BonusFrame:Show()
end
hooksecurefunc("BonusRollFrame_StartBonusRoll", BonusRollShow)

function Module:OnEnable()
  BonusRollShow() -- catch roll-on-load
  self:RegisterEvent("BONUS_ROLL_RESULT")
  self:RegisterEvent("CHAT_MSG_MONSTER_YELL")
  self:RegisterEvent("ENCOUNTER_END")
  self:RegisterEvent("BOSS_KILL")
  -- self:RegisterEvent("ADDON_LOADED") -- disabled due to reporting world bosses with `nil` as name
end

function Module:CHAT_MSG_MONSTER_YELL(event, msg, bossname)
  -- cheapest possible outdoor boss detection for players lacking a proper boss mod
  -- should work for sha and nalak, oon and gal report a related mob
  local t = SI.db.Toons[SI.thisToon]
  local now = time()
  if bossname and t then
    bossname = tostring(bossname) -- for safety
    local diff = select(4,GetInstanceInfo())
    if diff and #diff > 0 then bossname = bossname .. ": ".. diff end
    t.lastbossyell = bossname
    t.lastbossyelltime = now
    -- SI:Debug("CHAT_MSG_MONSTER_YELL: "..tostring(bossname));
  end
end

local getCurrentInstanceDifficulty = function()
  local difficultyID = GetBonusRollEncounterJournalLinkDifficulty and GetBonusRollEncounterJournalLinkDifficulty()
  if not difficultyID or difficultyID <= 0 then
    difficultyID = select(3, GetInstanceInfo())
  end
  return difficultyID
end

--- Record a recent boss kill in the given `SI.db.Toon[toon]`'s data store.
--- Used to track the correct recent boss to associate a bonus roll with.
--- @param toon string formatted as "Name - Server"
--- @param bossName string
--- @param difficultyID number
--- @param soft boolean?
local function recordBossToSavedVars(toon, bossName, difficultyID, soft)
  ---@type SavedInstances.Toon
  local toonData = SI.db.Toons[toon]
  if not toonData then return end
  local now = time()

  -- Note: some world bosses never send ENCOUNTER_END
  -- enough timeout to prevent overwriting, but short enough to prevent cross-boss contamination
  local lastKillTimestamp = toonData.lastbosstime or 0
  if soft == false
      and (not bossName or now <= lastKillTimestamp + 120)
  then
    return
  end

  local difficultyName = GetDifficultyInfo(difficultyID)
  if difficultyName and #difficultyName > 0 then
    bossName = bossName .. ": " .. difficultyName
  end
  toonData.lastboss = bossName
  toonData.lastbosstime = now
end

function Module:ENCOUNTER_END(event, encounterID, encounterName, difficultyID, raidSize, endStatus)
  SI:Debug("ENCOUNTER_END:%s:%s:%s:%s:%s",
    tostring(encounterID), tostring(encounterName), tostring(difficultyID), tostring(raidSize), tostring(endStatus)
  )
  if endStatus ~= 1 then return end -- wipe
  recordBossToSavedVars(SI.thisToon, tostring(encounterName), difficultyID)
  SI:RefreshLockInfo()
end
---@param encounterName string
function Module:BOSS_KILL(event, encounterID, encounterName, ...)
  SI:Debug("BOSS_KILL:%s:%s", tostring(encounterID), tostring(encounterName)) -- ..":"..strjoin(":",...))
  if encounterName and type(encounterName) == "string" then
    encounterName = encounterName:gsub(",.*$", "")                          -- remove extraneous trailing boss titles
    encounterName = strtrim(encounterName)
    recordBossToSavedVars(SI.thisToon, encounterName, getCurrentInstanceDifficulty(), true)
    SI:RefreshLockInfo()
  end
end

local handleBossModsEncounterEndEvent = function(source, bossName)
  SI:Debug("Boss Mod Kill - %s: %s", tostring(source), tostring(bossName))
  if not bossName or #bossName == 0 then return end
  recordBossToSavedVars(SI.thisToon, bossName, getCurrentInstanceDifficulty(), true)
  SI:RefreshLockInfo()
end

function Module:ADDON_LOADED(event, addonName)
  if DBM and DBM.EndCombat and not SI.dbmhook then
    SI.dbmhook = true
    hooksecurefunc(DBM, "EndCombat", function(self, mod, wipe)
      if wipe then return end -- ignore wipes
      local bossName = mod and mod.combatInfo and mod.combatInfo.name
      handleBossModsEncounterEndEvent("DBM:EndCombat", bossName)
    end)
  end
  if BigWigsLoader and not SI.bigwigshook then
    SI.bigwigshook = true
    BigWigsLoader.RegisterMessage(self, "BigWigs_OnBossWin", function(self, event, mod)
      handleBossModsEncounterEndEvent("BigWigs_OnBossWin", mod and mod.displayName)
    end)
  end
end

function Module:BONUS_ROLL_RESULT(event, rewardType, rewardLink, rewardQuantity, rewardSpecID, _, _, currencyID)
  local t = SI.db.Toons[SI.thisToon]
  SI:Debug("BONUS_ROLL_RESULT:%s:%s:%s:%s (boss=%s|%s)",
    tostring(rewardType), tostring(rewardLink), tostring(rewardQuantity), tostring(rewardSpecID),
    tostring(t and t.lastboss), tostring(t and t.lastbossyell))
  if not t then return end
  if not rewardType then return end -- sometimes get a bogus message, ignore it
  t.BonusRoll = t.BonusRoll or {}
  local now = time()
  local bossname
  -- Mythic+ Dungeon Roll
  -- if GetBonusRollEncounterJournalLinkDifficulty() == DifficultyUtil_ID_DungeonChallenge then
  --   local name, _, difficultyID, difficultyName = GetInstanceInfo()
  --   if difficultyID == DifficultyUtil_ID_DungeonChallenge then
  --     bossname = name .. ": " .. difficultyName
  --   else
  --     local tmp = {}
  --     for key, value in pairs(SI.db.History) do
  --       local _, name, _, diff = strsplit(":", key)
  --       if tonumber(diff) == DifficultyUtil_ID_DungeonChallenge then
  --         local tbl = {
  --           name = name .. ": " .. GetDifficultyInfo(diff),
  --           last = value.last,
  --         }
  --         tinsert(tmp, tbl)
  --       end
  --     end
  --     sort(tmp, function(l, r) return l.last > r.last end)
  --     bossname = tmp[1] and tmp[1].name
  --   end
  -- end
  if not bossname then
    bossname = t.lastboss
    if now > (t.lastbosstime or 0) + 3*60 then
      -- user rolled before lastboss was updated, ignore the stale one. Roll timeout is 3 min.
      bossname = nil
    end
    if not bossname and t.lastbossyell and now < (t.lastbossyelltime or 0) + 10*60 then
      bossname = t.lastbossyell -- yell fallback
    end
    if not bossname then
      bossname = GetSubZoneText() or GetRealZoneText() -- zone fallback
    end
  end
  local roll = {
    name = bossname,
    time = now,
    costCurrencyID = _G.BonusRollFrame.currencyID,
  }
  if rewardType == "money" then
    roll.money = rewardQuantity
  elseif rewardType == "currency" then
    roll.currencyID = currencyID
    roll.money = rewardQuantity
  elseif rewardType == "item" then
    roll.item = rewardLink
  end
  tinsert(t.BonusRoll, 1, roll)
  for i = MAX_BONUS_ROLL_RECORD_LIMIT + 1, #t.BonusRoll do
    t.BonusRoll[i] = nil
  end
end

---@param toon string name of the character to query
---@param currencyID number? bonus roll currency id, defaults to `BONUS_ROLL_REQUIRED_CURRENCY`
function Module:GetCharacterWeeklyRollCount(toon, currencyID)
  local t = SI.db.Toons[toon]
  if not t or not t.BonusRoll or #t.BonusRoll == 0 then return end
  if not currencyID or currencyID == 0 then currencyID = BONUS_ROLL_REQUIRED_CURRENCY end
  local count = 0
  local lastWeekReset = SI:GetNextWeeklyResetTime(-1)
  for _, trackedRoll in ipairs(t.BonusRoll) do
    if trackedRoll.costCurrencyID and trackedRoll.costCurrencyID == currencyID then
      if trackedRoll.time >= lastWeekReset then
        count = count + 1
      end
    end
  end
  return count
end

local ignoredBonusItems = {
  [163827] = true, -- Quartermaster's Coin, obtained when failing a bonus roll in pvp

  -- Unsure if the follow items count toward bad luck protection or not.
  [90839] = false, -- Cache of Sha-Touched Gold
  [90840] = false, -- Marauder's Gleaming Sack of Gold
}
---Number of times character has gotten gold or an item that counts towards BLP
---@return number? # nil if no bonus roll history found for character
function Module:GetCharacterBadLuckStreak(toon, currencyID)
  local t = SI.db.Toons[toon]
  if not t or not t.BonusRoll or #t.BonusRoll == 0 then return end
  local count = 0
  for _, trackedRoll in ipairs(t.BonusRoll) do
    if trackedRoll.costCurrencyID and trackedRoll.costCurrencyID == currencyID then
        if (not trackedRoll.item and trackedRoll.money and trackedRoll.money > 0)
        or (trackedRoll.item and ignoredBonusItems[GetItemInfoInstant(trackedRoll.item)])
        then
          count = count + 1
        else break; end
    end
  end
  return count
end
