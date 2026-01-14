---Notes:
--- MapID maps to DifficultyID and  ResetInterval in This table: https://wago.tools/db2/MapDifficulty?build=1.15.1.53009&filter[MapID]=48&page=1  
--- Can use DifficultyID + MapID to get the encounters and names in this table: https://wago.tools/db2/DungeonEncounter?build=1.15.1.53009&filter[Name_lang]=Ghamo&page=1
--- and to link MapID to lfgDungeonID use the localized named


--- This addon overuses saved variables, ideally any saved variables for expired data should be removed. The only long term data we really want to persist is stuff like currency and reputations. any character data without expiry. And maybe some collected/seen info relating to localization strings which the API doesn't directly provide a good way to obtain (ie encounter names).

--- consider caching any data you might need on addon loaded, try to find a good balance between loading everything on demands vs upfront. We also dont want to block the too long comming out of a loading screen.


---@class SavedInstances: AceEvent-3.0, Frame
---@field specialCurrency table<number, {weeklyMax: number?, earnByQuest: number[], relatedItem: {id: number, holdingMax: number?}}>
---@field private lastrefreshlocksched number?
---@field private PlayedTime number? Last time `Toon.PlayedLevel` and `Toon.PlayedTotal` were updated. Unix timestamp.
---@field private playedpending boolean? Whether `Toon.PlayedLevel` and `Toon.PlayedTotal` need to be updated.
---@field private playedreg table? *missing*
---@field private activeHolidays table<number|string, boolean>
---@field private instacesUpdated boolean? nil before first use in UI
---@field private RefreshPending boolean? flag for running `SI:Refresh` on next `SI:UpdateInstanceData`
---@field private delayUpdate number? Timestamp indicating when its okay for `SI:HistoryUpdate` to run. Used to delay updates while settings stabilize
---@field private histInGroup ("PARTY"|"RAID")? result of `SI:InGroup()` when `SI:HistoryUpdate` was last run. 
---@field hisLastZone string? Last instance zone seen by `SI:HistoryUpdate`
---@field private lasthistdbg string? Last history update's debug message.
---@field private histLiveCount number? Number of lockouts used towards the hourly limit. Calculated last time `SI:HistoryUpdate` was run.
---@field private histOldest string? Formatted remaining time until the oldest lockout towards the `histLimit` expires.
---@field private memusage number? Last memory usage reported by `SI:memcheck`
---@field private warned table<string, boolean>? list of localized dungeon names for which a dungeon missing bug report has been sent to the user.
---@field private KeystoneAbbrev table
local SI, L = unpack((select(2, ...)))

local QTip = SI.Libs.QTip
local db

-- Set the maximum LFG Dungeon ID to scan for instance data.
-- see https://wago.tools/db2/LFGDungeons? (filter by build) for highest possible value for an instanceID
-- just set this to a high enough number and eat the cost of the dead `GetLFGDungeonInfo` calls.
-- There are some manual entries tied to unused dungeon ids in the range.
-- eg: classic db table is missing Naxx/AQ20/40 which are spoofed as 159, 160 and 161.
-- See `SI:UpateInstanceData()`
local MAX_LFG_DUNGEON_ID =
  (SI.Enum.Expansion.Current > SI.Enum.Expansion.Classic)
    and 4000
    or 200 -- classic era has a lot less


-- Used for scanning lockout difficulties to display in the tooltip.
-- https://wago.tools/db2/Difficulty?sort[ID]=desc
-- cata (@4.4.2): 194 = "25 Player (Heroic)"
-- classic (@1.15.4): 231 = "Normal", this is flex SoD raids
-- mists: @5.5.0 = 237 "Celestial"
local MAX_DIFFICULTY_ID = 250

-- max columns per player+instance (in tooltip)
local MAX_COL_PER_CHARACTER = 4;

local table, math, bit, string, pairs, ipairs, unpack, strsplit, time, type, wipe, tonumber, select, strsub =
  table, math, bit, string, pairs, ipairs, unpack, strsplit, time, type, wipe, tonumber, select, strsub
local GetSavedInstanceInfo, GetNumSavedInstances, GetSavedInstanceChatLink, GetLFGDungeonNumEncounters, GetLFGDungeonEncounterInfo, GetNumRandomDungeons, GetLFGRandomDungeonInfo, GetLFGDungeonInfo, GetLFGDungeonRewards, GetTime, UnitIsUnit, GetInstanceInfo, IsInInstance, SecondsToTime, GetNumGroupMembers, UnitAura =
  GetSavedInstanceInfo, GetNumSavedInstances, GetSavedInstanceChatLink, GetLFGDungeonNumEncounters, GetLFGDungeonEncounterInfo, GetNumRandomDungeons, GetLFGRandomDungeonInfo, GetLFGDungeonInfo, GetLFGDungeonRewards, GetTime, UnitIsUnit, GetInstanceInfo, IsInInstance, SecondsToTime, GetNumGroupMembers, UnitAura


local C_QuestLog_GetTitleForQuestID = C_QuestLog.GetTitleForQuestID 
  or C_QuestLog.GetQuestInfo -- wotkl/era function equivalent

-- todo: refactor this spec api mess
-- compatibility for missing Spec API functionality.
local GetNumSpecializations = GetNumSpecializations
local GetSpecializationInfo = GetSpecializationInfo
local GetSpecializationInfoForSpecID = GetSpecializationInfoForSpecID

if not (GetNumSpecializations and GetSpecializationInfo and GetSpecializationInfoForSpecID) then
  if SI.isClassicEra then
      ---Get number of player specs
      ---@type fun():number
      GetNumSpecializations = GetNumTalentTabs

      ---Gets spec info for a spec tab index
      ---@param idx number
      ---@return number idx Same as passed arg
      ---@return string? name
      ---@return string? icon
      GetSpecializationInfoForSpecID = function(idx)
        local name, textureID = GetTalentTabInfo(idx) ---@type string?, string?
        return idx, name, textureID
      end

      -- Since wotlk has no specID's
      -- We treat the spec tab index and the specID as the same.
      GetSpecializationInfo = GetSpecializationInfoForSpecID
    else -- Mist of Pandaria api compatibility
      local _,_,classID = UnitClass("player")
      GetNumSpecializations = function() return C_SpecializationInfo.GetNumSpecializationsForClassID(classID) end
      ---@type fun(idx: number): number, string?, string?
      GetSpecializationInfoForSpecID = function(specID) return GetSpecializationInfoForClassID(classID, specID) end
      ---@type fun(idx: number): number, string?, string?
      GetSpecializationInfo = GetSpecializationInfoForSpecID
    end
end
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local FONTEND = FONT_COLOR_CODE_CLOSE or "\124r"

local GRAY = GRAY_FONT_COLOR ---@type ColorMixin
local PURE_GREEN = PURE_GREEN_COLOR ---@type ColorMixin
local GREEN = GREEN_FONT_COLOR ---@type ColorMixin
local RED = RED_FONT_COLOR ---@type ColorMixin
local LIGHTYELLOW = LIGHTYELLOW_FONT_COLOR ---@type ColorMixin
local GOLD = NORMAL_FONT_COLOR ---@type ColorMixin
local WHITE = HIGHLIGHT_FONT_COLOR ---@type ColorMixin

local INSTANCE_SAVED, TRANSFER_ABORT_TOO_MANY_INSTANCES, NO_RAID_INSTANCES_SAVED =
  INSTANCE_SAVED, TRANSFER_ABORT_TOO_MANY_INSTANCES, NO_RAID_INSTANCES_SAVED

local ALREADY_LOOTED = ERR_LOOT_GONE:gsub("%(.*%)","")
ALREADY_LOOTED = ALREADY_LOOTED:gsub("（.*）","") -- fix on zhCN and zhTW

local QuestExceptions = SI.QuestExceptions
local TimewalkingItemQuest = SI.TimewalkingItemQuest

local Config = SI:GetModule('Config')
local Tooltip = SI:GetModule('Tooltip')
local Progress = SI:GetModule('Progress')
local TradeSkill = SI:GetModule('TradeSkill')
local Currency = SI:GetModule('Currency')
local BonusRolls = SI:GetModule('BonusRolls', true) --[[@as BonusRollsModule?]]

---@cast Config ConfigModule
---@cast Tooltip TooltipModule
---@cast Progress ProgressModule
---@cast TradeSkill TradeSkillModule
---@cast Currency CurrencyModule

local Calling  ---@type AceModule?
local MythicPlus ---@type AceModule?
local Warfront ---@type AceModule?
if SI.isRetail then
  Calling = SI:GetModule('Calling')
  MythicPlus = SI:GetModule('MythicPlus')
  Warfront = SI:GetModule('Warfront')
end
local WorldBuffs 
if SI.isClassicEra then
  WorldBuffs = SI:GetModule('WorldBuffs') --[[@as WorldBuffsModule]]
end
local WorldBosses;
if SI.Enum.Expansion.Current >= SI.Enum.Expansion.Mists then
  WorldBosses = SI:GetModule('WorldBoss') --[[@as WorldBossesModule]]
end
SI.Indicators = {
  ICON_STAR = ICON_LIST[1] .. "16:16:0:0|t",
  ICON_CIRCLE = ICON_LIST[2] .. "16:16:0:0|t",
  ICON_DIAMOND = ICON_LIST[3] .. "16:16:0:0|t",
  ICON_TRIANGLE = ICON_LIST[4] .. "16:16:0:0|t",
  ICON_MOON = ICON_LIST[5] .. "16:16:0:0|t",
  ICON_SQUARE = ICON_LIST[6] .. "16:16:0:0|t",
  ICON_CROSS = ICON_LIST[7] .. "16:16:0:0|t",
  ICON_SKULL = ICON_LIST[8] .. "16:16:0:0|t",
  BLANK = "None",
}
-- More descript name.
-- an even more descript name would be "escapedIndictaorIcons"
SI.IndicatorIconTextures = SI.Indicators


-- Empty these tables as they're not needed for WotLK/Era, 
-- alternatively could add conditions wherever the table is accessed
-- this tables should be nil as theyre generated in files that are not specified to load in the TOC
-- for non retail versions of the addon
if not SI.isRetail then
  SI.LFRInstances = {}
  SI.Emissaries = {}
end

--- localized name of the expansion and the type of instance
--- ie `[D1] = "The Burning Crusade: Dungeon"`
--- or `[R0] = "Classic: Raid"`
local INSTANCE_CATEGORY_NAMES = {}
local MAX_EXPANSION
--- EXPANSION_LEVEL global refers to the id of the currently paid/active expansion for the logged in character. 
for i = 0, EXPANSION_LEVEL do
  local xpacName = _G["EXPANSION_NAME"..i]
  if xpacName then
    MAX_EXPANSION = i
    INSTANCE_CATEGORY_NAMES["D"..i] = xpacName .. ": " .. LFG_TYPE_DUNGEON
    INSTANCE_CATEGORY_NAMES["R"..i] = xpacName .. ": " .. LFG_TYPE_RAID
  else
    break
  end
end
SI.INSTANCE_CATEGORY_NAMES = INSTANCE_CATEGORY_NAMES

---Scrape and return the quest Title and hyperlink tooltip produced for given questID
---@param questID number
---@return string? name The quest name
---@return string? link `quest` type Hyperlink. 
function SI:QuestInfo(questID)
  if (not questID) or (questID == 0) then return end
  local questName = C_QuestLog_GetTitleForQuestID(questID)
  if (not questName) or (questName == "") then return end
  local linkTemplate = "\124cffffff00\124Hquest:%s:90\124h[%s]\124h\124r"
  local getQuestLink = function() 
    return linkTemplate:format(questID, questName)
  end
  
  SI:Debug("Scanning questID: ".. questID.." | Link: "..getQuestLink())
  -- SI.ScanTooltip:SetOwner(UIParent, 'ANCHOR_NONE')
  SI.ScanTooltip:SetHyperlink(getQuestLink())
  SI.ScanTooltip:Show()
  local title = _G[SI.ScanTooltip:GetName().."TextLeft1"] ---@type FontString
  questName = title and title:GetText() or ""

  -- only return the quest link if it produces a propper tooltip that contains the quest name in it.
  if #questName == 0 then return nil end
  return questName, getQuestLink()
end

--- Abbreviate expansion names (which apparently are not localized in any western character set)
---@param xpacName string
---@return string
local function abbreviate(xpacName)
  -- small amount of clauses doesnt justify a lookup
  if xpacName == "The Burning Crusade" then return "BC"
  elseif xpacName == "Wrath of the Lich King" then return "WotLK"
  elseif xpacName == "Cataclysm" then return "Cata"
  elseif xpacName == "Mists of Pandaria" then return "MoP"
  elseif xpacName == "Warlords of Draenor" then return "WoD"
  elseif xpacName == "Legion" then return "Legion"
  elseif xpacName == "Battle for Azeroth" then return "BfA"
  elseif xpacName == "Shadowlands" then return "SL" end;
  return xpacName;
end

function SI:formatNumber(num, isMoney)
  num = tonumber(num)
  if not num then return "" end
  local post = ""
  if isMoney then
    if num < 1000*10000 then -- less than 1k, show it all
      return GetMoneyString(num)
    end
    num = math.floor(num / 10000)
    post = " \124TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0\124t"
  end
  if SI.db.Tooltip.NumberFormat then
    local str = ""
    local neg = num < 0
    num = math.abs(num)
    local int = math.floor(num)
    local dec = num - int
    local t = tostring(int)
    if #t > 4 then -- leave 4 digit numbers
      while #t > 3 do
        str = LARGE_NUMBER_SEPERATOR .. t:sub(-3) .. str
        t = t:sub(1,-4)
    end
    end
    str = t..str
    if dec > 0 then
      str = str..string.format("%15g",dec):match("(%..*)$")
    end
    if neg then
      str = "-"..str
    end
    return str..post
  else
    return num..post
  end
end

---@alias SavedInstances.Toon.ShowState "always"|"never"|"saved"
---@alias SavedInstances.QuestDBQuestType "Daily"|"Weekly"|"AccountDaily"|"AccountWeekly"|"Darkmoon"
---@alias tooName string Characters name formatted "Name - Realm"

---@class QuestDBData : number, table

---@class SavedInstances.Toon.Currency
---@field amount number
---@field earnedThisWeek number?
---@field weeklyMax number?
---@field totalMax number?
---@field totalEarned number?
---@field relatedItemCount number?
---@field covenant table<1|2|3|4, number>?

---@class SavedInstances.Toon.Quest
---@field Title string
---@field Link string? In-game hyperlink.
---@field Zone UiMapDetails
---@field isDaily boolean? `true` if the quest is a daily reset quest.
---@field Expires number? For weekly or monthly quest expirations dates.
----@field type? "daily"|"weekly" 

---@class SavedInstances.Toon.Skill
---@field Title string
---@field Link string  SpellLink hyperlink.
---@field Expires number?

---------------------------------------------------
--- Todo Types: 
---------------------------------------------------
--- SavedInstances.Toon.BonusRoll
--- SavedInstances.Toon.MythicKey
--- {ResetTime: number?, }
--- SavedInstances.Toon.TimewornMythicKey
--- {ResetTime: number?, }
--- SavedInstances.Toon.MythicKeyBest
--- {ResetTime: number?, rewardWaiting: boolean?, [1-3]: any, lastCompletedIndex: number?, runHistory: table}
--- SavedInstances.Toon.Emissary
--- SavedInstances.Toon.Calling
--------------------------------------------------

---@class SavedInstances.Toon
---@field Class string Character's class "fileName" (used for indexing global tables)
---@field Level number
---@field Race string
---@field LastSeen number Last online.
---@field Order number Used for order in which characters are shown in the addon tooltip.
---@field Show SavedInstances.Toon.ShowState
---@field LFG1 number? Random dungeon cooldown expiry.
---@field LFG2 number? "Dungeon Deserter" debuff expiry.
---@field IL number? Character's Item level. (use `Toon.itemLevel` instead)
---@field itemLevel number? Character's Item level.
---@field ILe number? Character's *equipped* item level. (use `Toon.itemLevelEquipped` instead)
---@field itemLevelEquipped number? Character's *equipped* item level.
---@field ILPvp number? Character's PvP Item level. (use `Toon.itemLevelPvP` instead)
---@field itemLevelPvP number? Character's PvP Item level.
---@field Faction string Character's Faction name.
---@field LClass string Character's localized Class name.
---@field WeeklyResetTime number
---@field DailyResetTime number?
---@field PlayedLevel number? `/played` time for current level.
---@field PlayedTotal number? lifetime `/played` time for character.
---@field Money number
---@field Zone string?
---@field Warmode boolean? Unused in Wrath/Era.
---@field Covenant number? Unused in Wrath/Era.
---@field MythicPlusScore number? Unused in Wrath/Era.
---@field Paragon table? Unused in Wrath/Era.
---@field oRace string locale-independent race name.
---@field isResting boolean
---@field MaxXP number
---@field pvpdesert number? 
---@field XP number?
---@field RestXP number?
---@field Arena2v2rating number?
---@field Arena3v3rating number?
---@field RBGrating number? Unused in Wrath/Era.
---@field SoloShuffleRating table? Unused in Wrath/Era.
---@field SpecializationIDs table? keys: `1..GetNumSpecializations()`
---@field currency table<number, SavedInstances.Toon.Currency>
---@field Quests table<number, SavedInstances.Toon.Quest> Keyed by QuestID. Used to track *completed?* quests
---@field Skills table<number, SavedInstances.Toon.Skill> Keyed by SpellID or CDID.
---@field BonusRoll any? Unused in Wrath/Era.
---@field MythicKey any? Unused in Wrath/Era.
---@field TimewornMythicKey any? Unused in Wrath/Era.
---@field MythicKeyBest any? Unused in Wrath/Era.
---@field Emissary table? Unused in Wrath/Era.
---@field Progress table<string, QuestStore|QuestListStore> Unsure what key is 
---@field Warfront any? Unused in Wrath/Era.
---@field Calling any? Unused in Wrath/Era.
---@field lastboss string? Name of most recently killed boss, formatted `"BossName: DifficultyName"`
---@field lastbosstime number? Unix timestamp in seconds of most recently killed boss.
---@field WorldBuffs SavedInstances.Toon.WorldBuffs? Keyed by spellID. Only used in Classic Era.

--  [instance name] = {
--    Show: boolean
--    Raid: boolean
--    Holiday: boolean
--    Random: boolean
--    Expansion: integer
--    RecLevel: integer
--    LFDID: integer
--    LFDupdated: integer REMOVED
--    Encounters[integer] = { GUID : integer, Name : string } REMOVED
--    [Toon - Realm] = {
--      [Difficulty] = {
--        ID: integer, positive for a Blizzard Raid ID,
--        Expires: integer
--        Locked: boolean, whether toon is locked to the save
--        Extended: boolean, whether this is an extended raid lockout
--        Link: string hyperlink to the save in /raidinfo
--        [1..numEncounters]: boolean LFR isLooted
--      }
--    }
--  }

---If instance is an LFR, lockout info can be keyed by encounter index to check if said encounter has been completed for the week.
---@class SavedInstances.DB.Instance.LockoutInfo
---@field ID number the instance's `lockoutID` (as seen in /raidinfo). Set to `-1` for non-raid lockouts, and `-1*numBosses` for LFR wings.
---@field Expires number
---@field Locked boolean whether toon is locked to the save
---@field Extended boolean? whether this is an extended raid lockout
---@field Link string? hyperlink to the save in /raidinfo (doesnt work in either era or wotlk)
----@field type? "lfr"|"premade"|"random"|"holiday"|"scenario"|"worldboss" etc
---@field encounters {localizedName: string, isComplete: boolean}[]
---@field numEncounters integer
---@field numCompleted integer
---@field [number] boolean # LFR isLooted keyed by encounter index using `GetLFGDungeonEncounterInfo`

---Table containing info relating to the saved var `Instance` entry. Table can also be queried by [toonName][[difficultyID](https://wago.tools/db2/Difficulty)]
---mapping to a `SavedInstances.DB.Instance.LockoutInfo` table, 
---used for tracking a character's lockout information for this instance. 
---@class SavedInstances.DB.Instance.Entry
---@field Show SavedInstances.Toon.ShowState
---@field Raid boolean
---@field Holiday boolean
---@field Scenario boolean? Unused in Wotlk
---@field WorldBoss number? If a world boss, bosses encounterID. Unused in Wotlk
---@field Random boolean
---@field Expansion number
---@field RecLevel number
---@field LFDID number? https://warcraft.wiki.gg/wiki/LfgDungeonID (depracated)
---@field lfgDungeonID number https://warcraft.wiki.gg/wiki/LfgDungeonID (will use this field going forward)
---@field [tooName] {[number]: SavedInstances.DB.Instance.LockoutInfo }  Keyed by [toonName][[difficultyID](https://wago.tools/db2/Difficulty)]
---@field LFDupdated number? REMOVED
---@field Encounters table? REMOVED
---@field encountersByDifficulty {[number]: string[]} Keyed by difficultyID to get a list of localized encounter names.

--- The Addon's store. The data in this table is stored in blizzard's `SavedVariables` file for this addon.
---@class SavedInstances.DB
---@field DBVersion number Internal version of the database "schema".
---@field History table<string, {create: number, desc: string, last: number?}> For tracking instance per hour limit. Maps keys from `SI:histZoneKey` to value of `GetTime()` when instance was entered.
---@field histGeneration number Number in range [1-100000]. Defaults to `1`. Incremented when a instance reset is incurred while not in a zone. 
---@field Toons table<string, SavedInstances.Toon> Keyed by "Toon - Realm".
---@field spelltip table<number, string[]> Keyed by SpellID is any array of strings corresponding to the lines for the spells buff/debuff tooltip.
---@field Quests table<number, SavedInstances.Toon.Quest> Account-wide quests keyed by QuestID. Sames struct as `Toon.Quests`. 
---@field QuestDB table<SavedInstances.QuestDBQuestType, {expires?: number, [number]: number}> Permanent repeatable quest DBs each keyed by questID mapping to the quest's turnin location's mapID
---@field Warfront table? Unused in Wrath. todo define class `SavedInstances.DB.Warfront` using comment in defaultDB
---@field Emmisary table? Unused in Wrath. todo define class and subClasses `SavedInstances.DB.Emmisary` using comment in defaultDB
---@field RealmMap {[string]: number, [number]: string[]} Used to track connected realms. Keying by realm name returns an index. Keying by this index returns a table of connected realms.
---@field Instances table<string, SavedInstances.DB.Instance.Entry> Keyed by instance's lfg name. 
---@field DailyResetTime number? Unix timestamp in seconds of the next daily reset.
---@field Progress {["Enable"]: table<string, boolean>, ["Order"]: table<string, number>, ["User"]: table}
SI.defaultDB = {
  DBVersion = 12,
  histGeneration = 1,
  dbg = nil, ---@type boolean?
  History = { 
    -- key: instance string; value: time first entered
  },
  ---@see SavedInstances.Toon 
  Toons = { 
    -- [Toon Name] = {
      -- Class: string
      -- Level: integer
      -- Race: string
      -- LastSeen: integer
      -- AlwaysShow: boolean REMOVED
      -- Show: string "always", "never", "saved"
      -- Daily1: expiry (normal) REMOVED
      -- Daily2: expiry (heroic) REMOVED
      -- LFG1: expiry (random dungeon)
      -- LFG2: expiry (deserter)
      -- WeeklyResetTime: expiry
      -- DailyResetTime: expiry
      -- DailyCount: integer REMOVED
      -- PlayedLevel: integer
      -- PlayedTotal: integer
      -- Money: integer
      -- Zone: string
      -- Warmode: boolean
      -- Artifact: string REMOVED
      -- Cloak: string REMOVED
      -- Covenant: number
      -- MythicPlusScore: number
      -- Paragon: table
      -- oRace: string
      -- isResting: boolean
      -- MaxXP: integer
      -- XP: integer
      -- RestXP: integer
      -- Arena2v2rating: integer
      -- Arena3v3rating: integer
      -- RBGrating: integer
      -- SoloShuffleRating: table
      -- SpecializationIDs: table
      -- currency: key: currencyID  value:
      -- amount: integer
      -- earnedThisWeek: integer
      -- weeklyMax: integer
      -- totalMax: integer
      -- totalEarned: integer
      -- relatedItemCount: integer
      -- Quests:  key: QuestID  value:
      -- Title: string
      -- Link: hyperlink
      -- Zone: string
      -- isDaily: boolean
      -- Expires: expiration (non-daily)
    
      -- Skills: key: SpellID or CDID value:
      -- Title: string
      -- Link: hyperlink
      -- Expires: expiration
    
      -- BonusRoll: key: int value:
      -- name: string
      -- time: int
      -- costCurrencyID: int
      -- currencyID: int or nil
      -- money: integer or nil
      -- item: linkstring or nil
    
      -- MythicKey
      -- name: string
      -- ResetTime: expiry
      -- mapID: int
      -- level: int
      -- color: string
      -- link: string

      -- TimewornMythicKey
      -- name: string
      -- ResetTime: expiry
      -- mapID: int
      -- level: int
      -- color: string
      -- link: string
    
      -- MythicKeyBest
      -- ResetTime: expiry
      -- [1-3]: number
      -- lastCompletedIndex: number
      -- threshold[1-3]: number
      -- rewardWaiting: boolean
      -- [runHistory]: [
      --   completed,
      --   thisWeek,
      --   mapChallengeModeID,
      --   level,
      --   name,
      --   rewardLevel,
      -- }

      -- DailyWorldQuest REMOVED
      -- days[0,1,2]
      -- name
      -- dayleft
      -- questneed
      -- questdone
    
      -- Emissary
      -- [expansionLevel] = {
      --   unlocked = (boolean),
      --   days = {
      --     [Day] = {
      --       isComplete = isComplete,
      --       isFinish = isFinish,
      --       questDone = questDone,
      --       questReward = {
      --         money = money,
      --         itemName = itemName,
      --         itemLvl = itemLvl,
      --         quality = quality,
      --         currencyID = currencyID,
      --         quantity = quantity,
      --       },
      --     },
      --   },
      -- }
    
      -- Progress
      -- table<string, QuestStore|QuestListStore|table>
    
      -- Warfront
      -- [index] = {
      --   scenario = (boolean),
      --   boss = (boolean),
      -- }
    
      -- Calling
      -- unlocked = (boolean),
      -- [Day] = {
      --   isCompleted = isCompleted,
      --   expiredTime = expiredTime,
      --   isOnQuest = isOnQuest,
      --   questID = questID,
      --   title = title,
      --   text = text,
      --   objectiveType = objectiveType,
      --   isFinished = isFinished,
      --   questDone = questDone,
      --   questNeed = questNeed,
      --   questReward = {
      --     itemName = itemName,
      --     quality = quality,
      --   },
      -- }
    --}
  },
  ---@class SavedInstances.IndicatorFormatters
  Indicators = {
    D1Indicator = "BLANK", -- indicator: ICON_*, BLANK
    D1Text = "KILLED/TOTAL",
    D1Color = { 0, 0.6, 0 }, -- dark green
    D1ClassColor = true,
    D2Indicator = "BLANK",
    D2Text = "KILLED/TOTALH",
    D2Color = { 0, 1, 0 }, -- green
    D2ClassColor = true,
    D3Indicator = "BLANK",
    D3Text = "KILLED/TOTALM",
    D3Color = { 1, 0, 0 }, -- red
    D3ClassColor = true,
    R0Indicator = "BLANK",
    R0Text = "KILLED/TOTAL",
    R0Color = { 0.6, 0.6, 0 }, -- dark yellow
    R0ClassColor = true,
    R1Indicator = "BLANK",
    R1Text = "KILLED/TOTAL",
    R1Color = { 0.6, 0.6, 0 }, -- dark yellow
    R1ClassColor = true,
    R2Indicator = "BLANK",
    R2Text = "KILLED/TOTAL",
    R2Color = { 0.6, 0, 0 }, -- dark red
    R2ClassColor = true,
    R3Indicator = "BLANK",
    R3Text = "KILLED/TOTALH",
    R3Color = { 1, 1, 0 }, -- yellow
    R3ClassColor = true,
    R4Indicator = "BLANK",
    R4Text = "KILLED/TOTALH",
    R4Color = { 1, 0, 0 }, -- red
    R4ClassColor = true,
    R5Indicator = "BLANK",
    R5Text = "KILLED/TOTALL",
    R5Color = { 0, 0, 1 }, -- blue
    R5ClassColor = true,
    R6Indicator = "BLANK",
    R6Text = "KILLED/TOTAL",
    R6Color = { 0, 1, 0 }, -- green
    R6ClassColor = true,
    R7Indicator = "BLANK",
    R7Text = "KILLED/TOTALH",
    R7Color = { 1, 1, 0 }, -- yellow
    R7ClassColor = true,
    R8Indicator = "BLANK",
    R8Text = "KILLED/TOTALM",
    R8Color = { 1, 0, 0 }, -- red
    R8ClassColor = true,
  },
  ---@class SavedInstances.TooltipUserOptionsStore
  Tooltip = {
    posy = nil, ---@type number?
    posx = nil, ---@type number?
    DisableMouseover = false,
    ReverseInstances = false,
    ShowExpired = false,
    ShowHoliday = true,
    ShowRandom = true,
    DebugMode = false,
    CombineWorldBosses = false,
    CombineLFR = true,
    TrackDailyQuests = true,
    TrackWeeklyQuests = true,
    TrackDarkmoonQuests = SI.isCataclysm or nil,
    ShowCategories = false,
    CategorySpaces = false,
    RowHighlight = 0.1,
    Scale = 1,
    FitToScreen = true,
    NewFirst = true,
    RaidsFirst = true,
    NumberFormat = true,
    ---@type "EXPANSION"|"TYPE"
    CategorySort = "EXPANSION",
    ShowSoloCategory = SI.isClassicEra and true or false, -- default to true on era
    CurrencyHideUntracked = SI.isClassicEra and true or false,
    TrackWorldBuffs = SI.isClassicEra and true or nil,
    ShowHints = true,
    ReportResets = true,
    LimitWarn = true,
    HistoryText = false,
    ShowServer = false,
    ServerSort = true,
    ServerOnly = false,
    ---@type "group" | "ignore" | "interleave"
    ConnectedRealms = "group",
    SelfFirst = true,
    SelfAlways = false,
    TrackLFG = true,
    TrackDeserter = true,
    TrackSkills = true,
    TrackBonus = false,
    TrackPlayed = true,
    AugmentBonus = true,
    CurrencyValueColor = true,
    Currency2003 = true, -- Dragon Isles Supplies
    Currency2245 = true, -- Flightstones
    Currency2123 = true, -- Bloody Tokens
    Currency2797 = true, -- Trophy of Strife
    Currency2650 = true, -- Emerald Dewdrop
    Currency2651 = true, -- Seedbloom
    Currency2777 = true, -- Dream Infusion
    Currency2912 = true, -- Renascent Awakening
    Currency2806 = true, -- Whelpling's Awakened Crest
    Currency2807 = true, -- Drake's Awakened Crest
    Currency2809 = true, -- Wyrm's Awakened Crest
    Currency2812 = true, -- Aspect's Awakened Crest
    Currency2800 = true, -- 10.2.6 Professions - Personal Tracker - S4 Spark Drops (Hidden)
    Currency3010 = true, -- 10.2.6 Rewards - Personal Tracker - S4 Dinar Drops (Hidden)
    CurrencyMax = false,
    CurrencyEarned = true,
    CurrencySortName = false,
    MythicKey = true,
    TimewornMythicKey = true,
    MythicKeyBest = true,
    Emissary6 = false, -- LEG Emissary
    Emissary7 = false, -- BfA Emissary
    EmissaryFullName = true,
    EmissaryShowCompleted = true,
    CombineEmissary = false,
    AbbreviateKeystone = true,
    TrackParagon = true,
    Calling = true,
    CallingShowCompleted = true,
    CombineCalling = true,
    Warfront1 = false, -- Arathi Highlands
    Warfront2 = false, -- Darkshores
    ---@type "PARTY" | "GROUP" | "EXPORT"
    KeystoneReportTarget = "EXPORT",
  },
  ---@see SavedInstances.DB.Instances
  Instances = {}, 	
  MinimapIcon = { hide = false },
  Quests = {},
  QuestDB = {
    Daily = {},
    Weekly = {},
    Darkmoon = {},
    AccountDaily = {},
    AccountWeekly = {},
  },
  -- Track Warfronts
  Warfront = {
    -- [index] = {
    --   captureSide = ("Alliance" or "Horde"), -- Capture Side of Warfront
    --   contributing = (boolean), -- if it is contributing
    --   restTime = restTime, -- timeOfNextStateChange
    -- }
  },
  -- Track emissaries
  Emissary = {
    Cache = {
      -- [questID] = questName
    },
    Expansion = {
      -- [expansionLevel] = {
      --   [1, 2, 3] = {
      --     questID = {
      --       ["Alliance"] = questID,
      --       ["Horde"] = questID,
      --     },
      --     questNeed = questNeed,
      --     expiredTime = expiredTime,
      --   }
      -- }

    },
  },
  RealmMap = {},
  Progress = {
    Enable= {
      -- [progressEntryName]: boolean
    },
    Order = {
      -- [progressEntryName]: number
    },
    User = { 
      -- Unsure
    },
  },
}

-- skinning support
-- skinning addons should hook this function, eg:
--   hooksecurefunc(SavedInstances,"SkinFrame",function(self,frame,name) frame:SetWhatever() end)
function SI:SkinFrame(frame, name)
  -- default behavior (ticket 81)
  local IsAddOnLoaded = C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  if IsAddOnLoaded("ElvUI") or IsAddOnLoaded("Tukui") then
    if frame.StripTextures then frame:StripTextures() end
    if frame.CreateBackdrop then frame:CreateBackdrop("Transparent") end
    local closeButton = _G[name .. "CloseButton"] or frame.CloseButton
    if closeButton and closeButton.SetAlpha then
      if ElvUI then
        ElvUI[1]:GetModule('Skins'):HandleCloseButton(closeButton)
      end
      if Tukui and Tukui[1] and Tukui[1].SkinCloseButton then
        Tukui[1].SkinCloseButton(closeButton)
      end
      closeButton:SetAlpha(1)
    end
  end
end

-- general helper functions below

local function _startColorEscape(r,g,b,a)
  return format("|c%02x%02x%02x%02x", math.floor(a * 255), math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

local function startColorEscape(color)
  return _startColorEscape(color[1] or color.r,
    color[2] or color.g,
    color[3] or color.b,
    color[4] or color.a or 1)
end

local function ClassColorise(class, targetstring)
  ---@type string | ColorMixin_RCC
  local c = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[class]) or RAID_CLASS_COLORS[class]
  if c.colorStr then
    c = "|c"..c.colorStr
  else
    c = startColorEscape( c )
  end
  return c .. targetstring .. FONTEND
end

---Gets the color for a currency. Uses differnet colors to indicate progress towards a cap if `max` is defined.
---@param current number?
---@param max number?
---@param alt number?
---@return string
local function CurrencyColor(current, max, alt)
  current = current or 0
  local sAmt = SI:formatNumber(current)
  if max == nil or max == 0 then
    return sAmt
  end
  if SI.db.Tooltip.CurrencyValueColor then
    local pct = alt and (alt / max) or (current / max)
    ---@type ColorMixin
    local color = GREEN
    if pct >= 1 then
      color = RED
    elseif pct >= 0.75 then
      color = GOLD
    end
    return color:WrapTextInColorCode(sAmt)
  end
  return sAmt
end

local function TableLen(table)
  local i = 0
  for _, _ in pairs(table) do
    i = i + 1
  end
  return i
end

function SI:QuestIgnored(questID)
  if (SI.isRetail and TimewalkingItemQuest[questID]) and SI.activeHolidays then
    -- Timewalking Item Quests
    if SI.activeHolidays[TimewalkingItemQuest[questID]] then
      -- Timewalking Weedend Event ONGOING
      return
    end
    return true
  elseif Progress:QuestEnabled(questID) then
    return true
  end
end

--- Returns the number of daily and weekly quest *completed* for a toon or the account.
--- @param toonName? string Name of character formated "CharacterName - CharacterRealm". If `nil` uses account-wide quests data instead.
---@return integer dailyCount
---@return integer weeklyCount
function SI:QuestCount(toonName)
  local useAccountData = not toonName
  
  local trackedQuests = (useAccountData and SI.db.Quests)
    or (SI.db.Toons[toonName] and SI.db.Toons[toonName].Quests);
  if not trackedQuests then return 0, 0, 0 end
  
  local counts = {
    daily = 0,
    weekly = 0,
    dmf = 0
  }
  -- ticket 96: GetDailyQuestsCompleted() is unreliable, the response is laggy and it fails to count some quests
  for questID, questInfo in pairs(trackedQuests) do
    if not SI:QuestIgnored(questID) then
      -- original author assumed that if quest was not a "daily" then it was "weekly"
      -- not sure if this holds. depends on the usage of the Toon.Quests and DB.Quests tables.
      local isDMF = QuestExceptions[questID] == "Darkmoon"
      local cooldown = isDMF and "dmf" or (questInfo.isDaily and "daily" or "weekly")
      counts[cooldown] = counts[cooldown] + 1
    end
  end
  return counts.daily, counts.weekly, counts.dmf
end

-- local addon functions below

local function GetLastLockedInstance()
  local numsaved = GetNumSavedInstances()
  if numsaved > 0 then
    for i = 1, numsaved do
      local name, id, expires, diff, locked, extended, mostsig, raid, players, diffname = GetSavedInstanceInfo(i)
      if locked then
        return name, id, expires, diff, locked, extended, mostsig, raid, players, diffname
      end
    end
  end
end

--- Normalizes instance names by performing following operations:
-- 1. Remove all punctuation from the string.
-- 2. Replace all whitespace characters with a space.
-- 3. Replace all occurrences of two spaces with a single space.
-- 4. trim leading spaces.
-- 5. trim trailing spaces.
-- 6. Convert the entire string to uppercase.
---@param str string
---@return string
function SI:normalizeName(str)
  return str:gsub("%p",""):gsub("%s"," "):gsub("%s%s"," "):gsub("^%s+",""):gsub("%s+$",""):upper()
end

---Table used to for certain instances with miss matching LFD instance IDs and /raidinfo instance ids
---maps an instances /raidinfo hyperlink ID to the propper LFD ID
SI.transInstance = {
  [543] = 188, 	-- Hellfire Citadel: Ramparts
  [540] = 189, 	-- Hellfire Citadel: Shattered Halls : deDE
  [542] = 187,  -- Hellfire Citadel: Blood Furnace esES
  [534] = 195, 	-- The Battle for Mount Hyjal
  [509] = 160, 	-- Ruins of Ahn'Qiraj
  [557] = 179,  -- Auchindoun: Mana-Tombs : ticket 72 zhTW
  [556] = 180,  -- Auchindoun: Sethekk Halls : ticket 151 frFR
  [568] = 340,  -- Zul'Aman: frFR
  [1004] = 474, -- Scarlet Monastary: deDE
  [600] = 215,  -- Drak'Tharon: ticket 105 deDE
  [560] = 183,  -- Escape from Durnholde Keep: ticket 124 deDE
  [531] = 161,  -- AQ temple: ticket 137 frFR
  [1228] = 897, -- Highmaul: ticket 175 ruRU
  [552] = 1011, -- Arcatraz: ticket 216 frFR
  [1516] = 1190, -- Arcway: ticket 227/233 ptBR
  [1651] = 1347, -- Return to Karazhan: ticket 237 (fake LFDID)
  [545] = 185, -- The Steamvault: issue #143 esES
  [1530] = 1353, -- The Nighthold: issue #186 frFR
  [585] = 1154, -- Magisters' Terrace: issue #293 frFR
  [2235] = 1911, -- Caverns of Time - Anniversary: issue #315 (fake LFDID used by Escape from Tol Dagor)
  [725] = 320, -- The Stonecore: issue #328 frFR
  [2515] = 2335, -- The Azure Vault: issue #630 deDE
  [550] = 193, -- Tempest Keep: issue #612 ruRU
}

--- Some instances (like sethekk halls) are named differently by `GetSavedInstanceInfo()` and `LFGGetDungeonInfoByID()`.
--- We use the latter name to key our database, and this function to convert as needed
---@param name string? localized instance name.
---@param isRaid boolean? true if the instance is a raid.
---@return string? instanceKey Instance name, as used for a key in the `SavedInstances.DB.Instances` table.
---@return number? lfgDungeonID Instance's associated [LfgDungeonID](https://warcraft.wiki.gg/wiki/LfgDungeonID).
function SI:FindInstance(name, isRaid)
  if not name or #name == 0 then return nil end
  local normalizedName = SI:normalizeName(name)
  
  -- try the Instance info cache first
  -- (why not use the normalized name as a key for this table?)
  local instanceEntry = SI.db.Instances[name]
  if instanceEntry then
    return name, instanceEntry.lfgDungeonID
  end

  -- hyperlink id lookup: must precede substring match for ticket 99
  -- (so transInstance can override incorrect substring matches)

  -- Iterate the `/raidinfo` lockouts. Matches the passed normalized name to an entry in the /raidinfo by name,
  -- IF that matched /raidinfo entry has a corresponding entry in the `SI.transInstance` table
  -- then returns the localized name and *translated* lfgDungeonID.
  for i = 1, GetNumSavedInstances() do
      local link = GetSavedInstanceChatLink(i) or ""
      local idFromLink, nameFromLink = link:match(":(%d+):%d+:%d+\124h%[(.+)%]\124h")
      idFromLink = idFromLink and tonumber(idFromLink)
      local normalizedLinkName = nameFromLink and SI:normalizeName(nameFromLink)
      local normalizedID = idFromLink and SI.transInstance[idFromLink]
      if normalizedID and (normalizedLinkName == normalizedName) then
        local instanceKey = SI:UpsertInstanceByDungeonID(normalizedID)
        if instanceKey then
          return instanceKey, normalizedID
        end
      end
  end
  -- normalized substring match for any instances in saved vars.
  for instanceKey, instanceInfo in pairs(SI.db.Instances) do
    local normalizedKey  = SI:normalizeName(instanceKey)
    if (normalizedKey:find(normalizedName, 1, true) 
    or normalizedName:find(normalizedKey, 1, true)) 
    and instanceInfo.Raid == isRaid then -- Tempest Keep: The Botanica
      -- SI:Debug("FindInstance("..name..") => "..truename)
      return instanceKey, instanceInfo.lfgDungeonID
    end
  end
  return nil
end

--- Provide either id or name and raid status to get the instance's key and entry for/from `SI.db.Instances`.
---@param dungeonID number? [LfgDungeonID](https://warcraft.wiki.gg/wiki/LfgDungeonID).
---@param instanceName string? localized instance name.
---@param isRaid boolean?
---@return string? instanceKey
---@return SavedInstances.DB.Instance.Entry|{}? instanceEntry empty table or tableref to `SI.db.Instances[instanceKey]`
function SI:LookupInstance(dungeonID, instanceName, isRaid)
  -- SI:Debug("LookupInstance("..(id or "nil")..","..(name or "nil")..","..(raid and "true" or "false")..")")
  ---@type string?
  local instanceKey, entry = nil, {}
  if instanceName then
    --- Get any normalized name and the associated LFGDungeonID
    instanceKey, dungeonID = SI:FindInstance(instanceName, isRaid)
  end
  if dungeonID then -- either found or passed
    -- its possible an Upsert was already performed in `FindInstance`]
    -- this could just be extra work for no reason. 
    instanceKey = SI:UpsertInstanceByDungeonID(dungeonID)
  end
  if not instanceKey then return end

  entry = SI.db.Instances[instanceKey]
  if not entry then
    SI:Debug("LookupInstance failed to find instance: %s:%d : %s",
      instanceName or "", dungeonID or 0, GetLocale()
    )
    SI.warned = SI.warned or {}
    if instanceName and not SI.warned[instanceName]  then
      SI.warned[instanceName] = true
      local linkDungeonID
      for i = 1, GetNumSavedInstances() do
        local link = GetSavedInstanceChatLink(i) or ""
        local idFromLink, nameFromLink = link:match(":(%d+):%d+:%d+\124h%[(.+)%]\124h")
        if nameFromLink == instanceName then 
          linkDungeonID = idFromLink 
        end
      end
      SI:BugReport("SavedInstances: ERROR: Refresh() failed to find instance: "..instanceName.." : "..GetLocale().." : "..(linkDungeonID or "x"))
    end
    entry = {}
  end
  SI.db.Instances[instanceKey] = entry
  return instanceKey, entry
end

-- in this case a "category" is a string of the form "R{n}"|"D{n}"|"H"|"N" where n is the expansion number for that instance (0/1/2/.../n)
---@param instanceKey string?
---@return string?
function SI:GetInstanceCategory(instanceKey)
  if not instanceKey then return nil end
  local entry = SI.db.Instances[instanceKey]
  if entry.Holiday then return "H" end
  if entry.Random then return "N" end
  return ((entry.Raid and "R") or ((not entry.Raid) and "D")) .. entry.Expansion
end

--- Returns a list of instance keys that belong to the same category (as returned by `GetInstanceCategory`)
---@param targetCategory string
---@return string[]
function SI:GetCategoryInstances(targetCategory)
  -- returns a table of the form { "instance1", "instance2", ... }
  if (not targetCategory) then return { } end
  local list = { }
  for instanceKey, _ in pairs(SI.db.Instances) do
    if SI:GetInstanceCategory(instanceKey) == targetCategory then
      table.insert(list, instanceKey)
    end
  end
  return list
end

function SI:CategorySize(category)
  if not category then return nil end
  local i = 0
  for instance, _ in pairs(SI.db.Instances) do
    if category == SI:GetInstanceCategory(instance) then
      i = i + 1
    end
  end
  return i
end

---@type table<number, integer[]|integer> maps lfgDungeonID to either; a list npcIDs for the encounters of the instance, or a number that is total num of encounters.
local exceptionData = {
  -- workaround a Blizzard bug:
  -- since 5.0, some old raid lockout tooltips are missing boss kill info
  -- currently affects 25+ man BC/Vanilla raids (but not Kara or AQ Ruins, go figure)
  -- starting in 6.1 we have the kill bitmap but no boss names
  [48] = { -- Molten Core
    12118, -- Lucifron
    11982, -- Magmadar
    12259, -- Gehennas
    12057, -- Garr
    12264, -- Shazzrah
    12056, -- Baron Geddon
    12098, -- Sulfuron Harbinger
    11988, -- Golemagg the Incinerator
    12018, -- Majordomo Executus
    11502, -- Ragnaros
  },
  [50] = { -- Blackwing Lair
    12435, -- Razorgore the Untamed
    13020, -- Vaelastrasz the Corrupt
    12017, -- Broodlord Lashlayer
    11983, -- Firemaw
    14601, -- Ebonroc
    11981, -- Flamegor
    14020, -- Chromaggus
    11583, -- Nefarian
  },
  [161] = { -- Ahn'Qiraj Temple
    15263, -- Prophet Skeram
    15543, -- Princess Yauj (also Vem and Lord Kri)
    15516, -- Bodyguard Sartura
    15510, -- Fankriss the Unyielding
    15299, -- Viscidus
    15509, -- Princess Huhuran
    15276, -- Emperor Vek'lor
    15517, -- Ouro
    15727, -- C'Thun
  },
  [176] = { -- Magtheridon's Lair
    17257, -- Magtheridon
  },
  [177] = { -- Gruul's Lair
    18831, -- High King Maulgar
    19044, -- Gruul
  },
  [193] = { -- Tempest Keep
    19514, -- A'lar
    19516, -- Void Reaver
    18805, -- High Astromancer Solarian
    19622, -- Kael'thas Sunstrider
  },
  [194] = { -- Serpentshrine Cavern
    21216, -- Hydross the Unstable
    21217, -- The Lurker Below
    21215, -- Leotheras the Blind
    21214, -- Fathom-Lord Karathress
    21213, -- Morogrim Tidewalker
    21212, -- Lady Vashj
  },
  [195] = { -- Hyjal Past
    17767, -- Rage Winterchill
    17808, -- Anetheron
    17888, -- Kaz'rogal
    17842, -- Azgalor
    17968, -- Archimonde
  },
  [196] = { -- Black Temple
    22887, -- High Warlord Naj'entus
    22898, -- Supremus
    22841, -- Shade of Akama
    22871, -- Teron Gorefiend
    22948, -- Gurtogg Bloodboil
    22856, -- Reliquary of Souls
    22947, -- Mother Shahraz
    23426, -- Illidari Council
    22917, -- Illidan Stormrage
  },
  [199] = { -- Sunwell
    24850, -- Kalecgos
    24882, -- Brutallus
    25038, -- Felmyst
    25166, -- Grand Warlock Alythess
    25741, -- M'uru
    25315, -- Kil'jaeden
  },
  [1347] = 8, -- Return to Karazhan
  [1701] = 4, -- Siege of Boralus
}

---Cached localized boss names parsed from tooltip.
--- [dugeonID]: {[encounterNum]: bossName, ["total"]: totalEncounters, isPartial: boolean(private for cache)}
---@type {[integer]: {[integer]: string, total: integer, isPartial: boolean}}
local cachedLocalizations = { }

---@param dungeonID number
---@return {total: integer, [integer]: string}?
local getLocalizedExceptionData = function(dungeonID)
  --- parse execptions for localized bossnames via scraping a unit link tooltip. 
  if not exceptionData[dungeonID] then return nil end
  local cacheData = cachedLocalizations[dungeonID]
  if not cacheData or cacheData.isPartial then -- not cached yet
    cacheData = {}
    local encounters = exceptionData[dungeonID]
    if type(encounters) == "table" then
      SI:Debug("Scanning tooltip for Boss name info for dungeonID:%i", dungeonID)
      for idx, npcID in ipairs(encounters) do
        -- localize boss names
        SI.ScanTooltip:SetHyperlink(("unit:Creature-0-0-0-0-%d-0000000000"):format(npcID))
        SI.ScanTooltip:Show()  
        local line = _G[SI.ScanTooltip:GetName().."TextLeft1"]
        line = line and line:GetText() ---@type string?
        if line and #line > 0 then
          cacheData[idx] = line
        end
        SI.ScanTooltip:Hide()
      end
      if #cacheData ~= #encounters then
        SI:Debug("Scraped boss names for %s are incomplete. Total: %s/%s", dungeonID, #cacheData, #encounters)
        cacheData.isPartial = true
      end
      cacheData.total = #encounters
    else -- type == "number"
      cacheData.total = encounters
    end
    assert(cacheData.total, "`total` encounters not found for "..dungeonID.." in `exceptionData`. Set a table of bossIDs or number")
    cachedLocalizations[dungeonID] = cacheData
    SI:Debug("Boss name info cached successfully for %s", dungeonID)
  end
  return cacheData
end
---Returns string array of localized encounter boss names with `total` field.
---@param dungeonID number
---@return {total: integer, [integer]: string}? encounters
function SI:GetInstanceExceptionInfo(dungeonID)
  if not dungeonID then return nil end
  return getLocalizedExceptionData(dungeonID)
end

---get the boss encounter progress for a given instance, toon, and difficulty
---@param instanceKey string
---@param toon string
---@param difficultyID number
---@return integer completed
---@return integer total
---@return integer base 
---@return table? remap # used by LFR entries
---@return table? origin # used by LFR entries
function SI:GetInstanceEncounterProgress(instanceKey,toon,difficultyID)
  if not (instanceKey and toon and difficultyID) then return 0,0,1 end
  local instance = SI.db.Instances[instanceKey]
  local lockoutInfo = instance and instance[toon] and instance[toon][difficultyID]
  --- going forward i want to try to colect this data before hand, and calculate it as a last resort. Ideally it should be cached and ready for when the tooltip is show and this function is called.
  
  if lockoutInfo and lockoutInfo.numEncounters and lockoutInfo.numCompleted then
    ---@diagnostic disable-next-line: undefined-field
    return lockoutInfo.numCompleted, lockoutInfo.numEncounters, 1, lockoutInfo.remap, lockoutInfo.origin
  end

  local killed, total, base = 0, 0, 1
  local remap, origin
  if instance.WorldBoss then
    -- World bosses are treated as encounter 1 of an LFR lockout
    local isKilled = lockoutInfo and lockoutInfo[1]
    return (isKilled and 1 or 0), 1, 1, nil
  end
  if not instance or not instance.lfgDungeonID then return 0,0,1 end
  local encounters = SI:GetInstanceExceptionInfo(instance.lfgDungeonID)
  --- in classic era `GetLFGDungeonNumEncounters` returns 0. 
  total = (encounters and encounters.total) or GetLFGDungeonNumEncounters(instance.lfgDungeonID)
  local LFR = SI.LFRInstances[instance.lfgDungeonID]
  if LFR then
    total = LFR.total or total
    base = LFR.base or base
    remap = LFR.remap
    origin = LFR.origin
  end
  if not lockoutInfo then
    return killed, total, base, remap, origin
  elseif lockoutInfo.Link then
    local bits = lockoutInfo.Link:match(":(%d+)\124h")
    bits = bits and tonumber(bits)
    if bits then
      if instance.lfgDungeonID == 1944 then
        -- Battle of Dazar'alor
        -- https://github.com/SavedInstances/SavedInstances/issues/233
        if SI.db.Toons[toon].Faction == "Alliance" then
          bits = bit.band(bits, 0x3134D)
        else
          bits = bit.band(bits, 0x3135A)
        end
      end
      while bits > 0 do
        if bit.band(bits,1) > 0 then
          killed = killed + 1
        end
        bits = bit.rshift(bits,1)
      end
    end
  ---Set to `-1` for non-raid lockouts, and `-1*numBosses` for LFR wings.
  elseif lockoutInfo.ID < 0 then
    for i=1,-1*lockoutInfo.ID do
      killed = killed + (lockoutInfo[i] and 1 or 0)
    end
  end
  total = max(total, killed) -- incase no total is found. assume most killed is total. 
  return killed, total, base, remap, origin
end

local lfrkey = "^"..L["LFR"]..": "
local function instanceSort(i1, i2)
  local instance1 = SI.db.Instances[i1]
  local instance2 = SI.db.Instances[i2]
  local level1 = instance1.RecLevel or 0
  local level2 = instance2.RecLevel or 0
  local id1 = instance1.lfgDungeonID or instance1.WorldBoss or 0
  local id2 = instance2.lfgDungeonID or instance2.WorldBoss or 0
  local key1 = level1*1000000+id1
  local key2 = level2*1000000+id2
  if i1:match(lfrkey) then key1 = key1 - 20000 end
  if i2:match(lfrkey) then key2 = key2 - 20000 end
  if instance1.WorldBoss then key1 = key1 - 30000 end
  if instance2.WorldBoss then key2 = key2 - 30000 end
  if SI.db.Tooltip.ReverseInstances then
    return key1 < key2
  else
    return key2 < key1
  end
end

SI.oi_cache = {} ---@type string[][]
--- Returns a table in of the form `{ "instance1", "instance2", ... }` containing instance names for valid expansions. Uses the table `SI.oi_cache[category]` as a cache.
--- @param category string
--- @return string[]
function SI:OrderedInstances(category)
  local instances = SI.oi_cache[category]
  if not instances then
    instances = SI:GetCategoryInstances(category)
    table.sort(instances, instanceSort)
    if SI.instancesUpdated then
      SI.oi_cache[category] = instances
    end
  end
  return instances
end

--- Returns a table in of the form `{ "R0", "D0", "R1", ... }` containing instance categories for valid expansions. 
-- Uses the table `SI.oc_cache` as a cache.
--- @return string[] 
function SI:OrderedCategories()
  -- if oc_cache is create with EXPANSION and then this is changed to "TYPE" wont get get oc_cache for the wrong list if we dont invalidate the cache?
  
  -- if SI.oc_cache then return SI.oc_cache end
  local orderedlist = { }

  local xpacStart, xpacEnd, step;
  if SI.db.Tooltip.NewFirst then
    xpacStart = MAX_EXPANSION
    xpacEnd = 0
    step = -1
  else
    xpacStart = 0
    xpacEnd = MAX_EXPANSION
    step = 1
  end

  local startType, endType;
  if SI.db.Tooltip.RaidsFirst then
    startType = "R"
    endType = "D"
  else
    startType = "D"
    endType = "R"
  end

  for xpac = xpacStart, xpacEnd, step do
    table.insert(orderedlist, startType .. xpac)
    -- if sort by set to "expansion" then add the other "types" for this expansion after the initial
    -- otherwise add the next expansion with the same inital type
    if SI.db.Tooltip.CategorySort == "EXPANSION" then
      table.insert(orderedlist, endType .. xpac)
    end
  end
  -- if sort by set to "type" then add the other "types" for all expansions (in order specified by most recent first)
  if SI.db.Tooltip.CategorySort == "TYPE" then
    for i = xpacStart, xpacEnd, step do
      table.insert(orderedlist, endType .. i)
    end
  end
  SI.oc_cache = orderedlist
  -- SI:Debug("OrderedCategories sorted")
  -- DevTools_Dump(orderedlist)
  return orderedlist
end

---Retrun formatted string for a lockouts encounter progress. ie "10/12H" for heroic lockout with 10 of 12 encounters completed.
---@param instanceKey string? key to `SI.db.Instances`
---@param diffID number [DifficultyID](https://wow.gamepedia.com/DifficultyID)
---@param toon string key to `SI.db.Toons`
---@param isExpired boolean? true if the lockout is expired.
---@param _kills number? override the number of boss kills to show on tooltip
---@param _total number? override the total number of bosses shown on tooltip
---@return string?
local function DifficultyString(instanceKey, diffID, toon, isExpired, _kills, _total)
  local category, color
  if not instanceKey then
    category = "D1"
  else
    local instance = SI.db.Instances[instanceKey]
    if not SI.isRetail then
      assert(diffID, "DifficultyID is required to generate a `DifficultyString` for non retail client.")
      category = SI.getDifficultyCategory(diffID)
    elseif not instance or not instance.Raid then -- 5-man
      if diffID == 2 then -- heroic
        category = "D2"
    elseif diffID == 23 then -- mythic
      category = "D3"
    else -- normal?
      category = "D1"
    end
    elseif instance.Expansion == 0 then -- classic raid
      category = "R0"
    elseif diffID >= 3 and diffID <= 7 then -- pre-WoD raids
      category = "R"..(diffID-2)
    elseif diffID >= 14 and diffID <= 16 then -- WoD raids
      category = "R"..(diffID-8)
    elseif diffID == 17 then -- Looking For Raid
      category = "R5"
    else -- don't know
      category = "D1"
    end
  end
  local _categoryNew = SI.getDifficultyCategory(diffID)
  if not (category == _categoryNew) then 
    SI:Debug("Expected category mismatch. old=%s, new=%s, diffID=%s, instance=%s", category, _categoryNew, diffID, instanceKey)
    -- there a mismatch for AQ20 in retail wow.
    -- AQ20 had its lockout updated to a 10/25man at some point
    -- so it doesnt get the difficultyID used for 20m 
    -- this is an exception that needs to be handled-
    -- at some point in our info pipeline.
  end
  category = _categoryNew
  -- Category Here is just used for coloring. 
  local userIndicators = SI.db.Indicators
  local defaultIndicators = SI.defaultDB.Indicators

  ---@type boolean?
  local useClassColor;
  if userIndicators[category .. "ClassColor"] ~= nil then
    useClassColor = userIndicators[category .. "ClassColor"]
  else useClassColor = defaultIndicators[category .. "ClassColor"] end

  -- SI:Debug("Generating Difficulty String for %s on %s: %s", instanceKey or 'nil', toon, category)
  -- SI:Debug("use ClassColor: %s", useClassColor and "true" or "false")     
  if isExpired then
    color = GRAY
  elseif useClassColor then
    color = (CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[SI.db.Toons[toon].Class]) 
      or RAID_CLASS_COLORS[SI.db.Toons[toon].Class]
  else -- use color picker color
    userIndicators[category.."Color"]  = userIndicators[category.."Color"] or defaultIndicators[category.."Color"]
    color = userIndicators[category.."Color"]
  end
  ---@type string
  local progressText = userIndicators[category.."Text"] or defaultIndicators[category.."Text"]
  local indicatorIcon = userIndicators[category.."Indicator"] or defaultIndicators[category.."Indicator"]
  local displayStr = progressText

  displayStr = (color.WrapTextInColorCode 
    and color:WrapTextInColorCode(displayStr))
    or (startColorEscape(color) .. displayStr .. FONTEND);
  
  -- if using a non blank icon add it too
  if displayStr:find("ICON", 1, true) and indicatorIcon ~= "BLANK" then
    displayStr = displayStr:gsub("ICON", FONTEND .. SI.IndicatorIconTextures[indicatorIcon] .. startColorEscape(color))
  end
  if displayStr:find("KILLED", 1, true) or displayStr:find("TOTAL", 1, true) then
    ---@type string|number?, string|number?
    local killed, total;

    --- how often is this kill override even used?? seems to just muddy the logic.
    if _kills then
      killed, total = _kills, _total
    elseif instanceKey then
      killed, total = SI:GetInstanceEncounterProgress(instanceKey,toon,diffID)
      SI:Debug("Encounter progress for %s on %s: %i of %i", instanceKey, toon, (killed or -1), (total or -1))
    end
    
    if killed == 1 and total == 1 and not isExpired then
      displayStr = SI.questCheckMark
    end
    
    -- boss kill info missing
    killed = (killed and killed ~= 0) and killed or "*"
    total = (total and total ~= 0) and total or "*"
    
    displayStr = displayStr:gsub("KILLED",killed)
    displayStr = displayStr:gsub("TOTAL", total)
  end
  return displayStr
end

-- Update saved variables db with fresh instance info.
-- Updates data for all dungeonId's and worldBosses
-- attempts to merge any character lockout data for any instances whos 
-- static info has been changed (ie lfgDungeonID/encounterID/instanceKey)
-- changes are recieved from a call to `SI:UpdateInstance`
-- run about once per session to update our database of instance info
function SI:UpdateInstanceData()
  -- SI:Debug("UpdateInstanceData()")
  if SI.instancesUpdated then return end  -- nil before first use in UI
  SI.instancesUpdated = true
  local newInstanceCount = 0
  local dungeonInstanceKeys = {}
  local worldBossInstanceKeys = {}
  local dungeonIdBlacklist = {}
  local profilingStart = debugprofilestop()

  --- Update LFG Dungeon data
  --- previously we used GetFullRaidList() and LFDDungeonList to help populate the instance list
  --- Unfortunately those are loaded lazily, and forcing them to load from here can lead to taint.
  --- They are also somewhat incomplete, so instead we just brute force it, which is reasonably fast anyhow
  for dungeonID = 1, MAX_LFG_DUNGEON_ID do
    local instanceKey, isNewInstance, isBlacklist = SI:UpsertInstanceByDungeonID(dungeonID)
    if isNewInstance then
      newInstanceCount = newInstanceCount + 1
    end
    if isBlacklist then
      dungeonIdBlacklist[dungeonID] = true
    end
    if instanceKey then 
      -- Only for debug purposes
      if dungeonInstanceKeys[dungeonID] then
        SI:Debug("Duplicate entry in lfdid_to_name: "..dungeonID..":"..dungeonInstanceKeys[dungeonID]..":"..instanceKey)
      end

      dungeonInstanceKeys[dungeonID] = instanceKey
    end
  end
  -- Season of Discovery specific instances.
  if SI.isSoD then
    local addInstance = function(spoofLfgID)
      local instanceKey, isNewInstance  = SI:UpsertInstanceByDungeonID(spoofLfgID)
      assert(instanceKey, "Expected hardcoded data to be provided for spoofed ID in `UpdateInstanceByDungeonID`", spoofLfgID)
      if isNewInstance then newInstanceCount = newInstanceCount + 1 end
        if dungeonInstanceKeys[spoofLfgID] then -- Only for debug purposes
          SI:Debug("Duplicate entry in lfdid_to_name: "..spoofLfgID..":"..dungeonInstanceKeys[spoofLfgID]..":"..instanceKey)
        end
        dungeonInstanceKeys[spoofLfgID] = instanceKey
    end
    -- Note: Going to use lfg dungeon ids starting at 10001 to spoof these. 
    -- See `UpsertInstanceByDungeonID` for the spoofed data.
    addInstance(10001) -- Storm Cliffs - Azuregos
    addInstance(10002) -- Tainted Scar - Lord Kazzak
    addInstance(10003) -- Crystal Vale - Thunderaan
    addInstance(10004) -- Karazhan Crypts
    addInstance(10005) -- Scarlet Enclave
    addInstance(10006) -- Nightmare Grove
  end

  --- Update the world boss data
  if WorldBosses then
    local addedBosses = WorldBosses:UpdateInstanceStoreInfo()
    newInstanceCount = newInstanceCount + addedBosses
    for encounterID, boss in WorldBosses:IterateBossEncounterInfo() do
      worldBossInstanceKeys[encounterID] = boss.name
    end
  end

  -- Instance Merging
  -- this algorithm removes duplicate entries created by client locale changes using the same database
  -- we really should re-key the database by ID, but this is sufficient for now
  local renames = 0
  local merges = 0
  local conflicts = 0
  for currentKey, currentInstance in pairs(SI.db.Instances) do
    local freshInstanceKey ---@type string?
    if currentInstance.WorldBoss then
      freshInstanceKey = worldBossInstanceKeys[currentInstance.WorldBoss]
    elseif currentInstance.lfgDungeonID then
      freshInstanceKey = dungeonInstanceKeys[currentInstance.lfgDungeonID]
    else
      SI:Debug("Ignoring bogus entry in instance database: "..currentKey)
    end
    local shouldUpdateInstance = currentKey ~= freshInstanceKey 
    
    -- if stale entry, merge data and remove it
    if freshInstanceKey and shouldUpdateInstance then 
      assert(type(freshInstanceKey) == "string")
      ---@cast freshInstanceKey string

      local freshInstance = SI.db.Instances[freshInstanceKey]
      
      -- Renaming these here for clarity
      local staleInstanceKey, staleInstance = currentKey, currentInstance 
      
      if not freshInstance or (freshInstance == staleInstance) then
        SI:Debug("Merge error in UpdateInstanceData: "..freshInstanceKey)
      else
        --- attempt to merge any character data 
        for entryField, staleData in pairs(staleInstance) do
          ---@cast entryField string
          local characterKey = entryField:find(" - ") and entryField
          -- If the field is a character key 
          if characterKey then -- ie "toonName - toonRealm"
            -- and character entry exists in fresh instance
            if freshInstance[characterKey] then
              -- then we have a merge conflict: Keep the fresh data
              SI:Debug("Merge conflict on "..
                freshInstanceKey..":"..staleInstanceKey..":"..entryField
              )
              conflicts = conflicts + 1
            else
              -- otherwise copy K:V pair from stale instance to fresh instance
              freshInstance[entryField] = staleData
              merges = merges + 1
            end
          end
        end
        -- copy config settings, favoring old entry
        freshInstance.Show = staleInstance.Show
        -- clear stale entry
        SI.db.Instances[staleInstanceKey] = nil
        renames = renames + 1
      end
    elseif not freshInstanceKey then -- if a new kew is not found
      -- and if missing becuase its been added the instance blacklist
      if dungeonIdBlacklist[currentInstance.lfgDungeonID] then
        SI:Debug("Removing blacklisted entry in instance database: "
          ..currentKey
        )
        -- if it is nil the entry in the saved db
        SI.db.Instances[currentKey] = nil
      else
        SI:Debug("Ignoring unmatched entry in instance database: "
          ..currentKey
        )
      end
    end
  end
  -- should this be called in here? is there a better spot to be calling for an options rebuild.
  Config:BuildAceConfigOptions() -- refresh config table

  local elapsedTime = debugprofilestop() - profilingStart
  SI:Debug("UpdateInstanceData(): completed in %.3f ms : %d added, %d renames, %d merges, %d conflicts.",
  elapsedTime, newInstanceCount, renames, merges, conflicts)
  
  if SI.RefreshPending then
    SI.RefreshPending = nil
    SI:Refresh()
  end
end

--if LFDParentFrame then hooksecurefunc(LFDParentFrame,"Show",function() SI:UpdateInstanceData() end) end

--- Updates/inserts the information pertaining to given ID, in the `SI.db.Instances` table.
---@param dungeonID number [LfgDungeonID](https://warcraft.wiki.gg/wiki/LfgDungeonID)
---@return string? instanceKey Key used to query this dungeon from the `SI.db.Instances` table. Usually dungeon name, prepended with "LFR: " if an LFR instance.
---@return boolean? isNewInstance True if the instance was newly added to the database
---@return boolean? isBlacklisted True if the instanceID is blacklisted
function SI:UpsertInstanceByDungeonID(dungeonID)
  -- SI:Debug("UpdateInstance: "..id)
  if not dungeonID or dungeonID <= 0 then return end
  -- local lfgName, typeID, subtypeID,
  --   minLevel, maxLevel, recLevel, minRecLevel, maxRecLevel,
  --   expansionLevel, groupID, textureFilename,
  --   difficulty, maxPlayers, description, isHoliday = GetLFGDungeonInfo(dungeonID)
  --    -- https://warcraft.wiki.gg/wiki/API_GetLFGDungeonInfo
     
  -- https://warcraft.wiki.gg/wiki/API_GetLFGDungeonInfo
  local dungeonInfo = SafePack(GetLFGDungeonInfo(dungeonID))

  -- The name of the dungeon/event
  local lfgName = dungeonInfo[1] ---@type string? 
  
  local typeID = dungeonInfo[2] ---@type number
  -- See 'InstanceType'
  -- https://wago.tools/db2/Difficulty?build=10.2.5.53262&page=1&sort[InstanceType]=asc
  -- 1=TYPEID_DUNGEON or LFR, 2=raid instance, 4=outdoor area, 6=TYPEID_RANDOM_DUNGEON, 5 = bg
  -- it looks like 6 is no longer used tho.
  local hasValidTypeID = function()
    local validTypes
    if SI.isClassicEra then
      -- dungeon and raid
      validTypes = {1, 2}
    else
      validTypes = {1, 2, 6}
    end
    return tContains(validTypes, typeID)
  end
  
  -- 0=Unknown, 1=LFG_SUBTYPEID_DUNGEON, 2=LFG_SUBTYPEID_HEROIC, 3=LFG_SUBTYPEID_RAID,
  -- 4=LFG_SUBTYPEID_SCENARIO, 5=LFG_SUBTYPEID_FLEXRAID
  local subtypeID = dungeonInfo[3] ---@type number 
  
  -- Recommended level to queue for this dungeon
  local recLevel = dungeonInfo[6] ---@type number?
  if not recLevel or recLevel == 0 then
    local min, max = dungeonInfo[4], dungeonInfo[5]
    if min and max then recLevel = (min + max) / 2 end
  end
  -- Refers to `GetAccountExpansionLevel()` values
  local expansionLevel = dungeonInfo[9] ---@type number? 
  local difficultyID = dungeonInfo[12] ---@type number
  local maxPlayers = dungeonInfo[13] ---@type number 
  local isHoliday = dungeonInfo[15] ---@type boolean 
  -- name is nil for non-existent ids
  -- isHoliday is for single-boss holiday instances that don't generate raid saves
  -- typeID 4 = outdoor area, typeID 6 = random
 
  -- maxPlayers = tonumber(maxPlayers) already assumed to be a `number|nil`
  
  -- if instance 10v10 rated bg then ignore it. return `isBlackListed=true`

  -- Edge cases handled below.
  if dungeonID == 1347 then -- ticket 237: Return to Karazhan currently has no actual LFDID, so use this one (Kara Scenario)
    lfgName = SPLASH_LEGION_NEW_7_1_RIGHT_TITLE
    expansionLevel = 6
    recLevel = 110 -- not sure if this is still valid after lvl squish 
    maxPlayers = 5
    isHoliday = false
    typeID = TYPEID_DUNGEON
    subtypeID = LFG_SUBTYPEID_HEROIC
  elseif dungeonID == 1911 then -- Caverns of Time - Anniversary: issue #315 (fake LFDID used by Escape from Tol Dagor)
    local dungeonInfo = SafePack(GetLFGDungeonInfo(2004))
    -- name2 as returned by `GetSavedInstanceInfo()`.
    lfgName = dungeonInfo[19] ---@type string?
    typeID = dungeonInfo[2] ---@type number
    subtypeID = dungeonInfo[3] ---@type number
    recLevel = dungeonInfo[6] ---@type number?
    expansionLevel = dungeonInfo[9] ---@type number?
    difficultyID = dungeonInfo[12] ---@type number
    maxPlayers = dungeonInfo[13]  ---@type number
    isHoliday = dungeonInfo[15] ---@type boolean
    if not (lfgName and expansionLevel and recLevel) then return end 
  elseif dungeonID == 842 then -- Downfall (#308) different name for origin and solo LFG in deDE
    if SI.locale == 'deDE' then
      lfgName = "Niedergang"
    end
  elseif dungeonID == 160 and not lfgName then -- GetLFGDungeonInfo() is `nil` in 1.15.1 client for next 3 dungeons
    -- Ruins of Ahn'Qiraj
    lfgName = GetRealZoneText(509)
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 20
    isHoliday = false
    difficultyID = 148 -- 20m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 161 and not lfgName then 
    -- Temple of Ahn'Qiraj
    lfgName = GetRealZoneText(531)
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    isHoliday = false
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 159 and not lfgName then -- Naxx
    lfgName = GetRealZoneText(533)
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 10001 and SI.isSoD then -- Storm Cliffs: Azuregos
    lfgName = GetRealZoneText(2791)
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 10002 and SI.isSoD then -- Tainted Scar: Kazzak
    lfgName = GetRealZoneText(2789)
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 10003 and SI.isSoD then -- Crystal Vale: Thunderaan
    lfgName = GetRealZoneText(2804)
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 10004 and SI.isSoD then -- 	Karazhan Crypts
    local activityInfo = C_LFGList.GetActivityInfoTable(1693)
    lfgName = activityInfo.shortName and activityInfo.shortName ~= "" and activityInfo.fullName or activityInfo.fullName
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 5
    typeID = 1
    subtypeID = LFG_SUBTYPEID_DUNGEON
  elseif dungeonID == 10005 and SI.isSoD then -- Scarlet Enclave
    local activityInfo = C_LFGList.GetActivityInfoTable(1710)
    lfgName = activityInfo.shortName and activityInfo.shortName ~= "" and activityInfo.fullName or activityInfo.fullName
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  elseif dungeonID == 10006 and SI.isSoD then -- Nightmare Grove
    local activityInfo = C_LFGList.GetActivityInfoTable(1610)
    lfgName = activityInfo.shortName and activityInfo.shortName ~= "" and activityInfo.fullName or activityInfo.fullName
    expansionLevel = 0
    recLevel = 60
    maxPlayers = 40
    difficultyID = 9 -- 40m
    typeID = 2
    subtypeID = LFG_SUBTYPEID_RAID
  end

  if subtypeID == LFG_SUBTYPEID_SCENARIO and typeID ~= TYPEID_RANDOM_DUNGEON then -- ignore non-random scenarios
    return nil, nil, true
  end
  if typeID == 2 and subtypeID == 0 and difficultyID == 17 and maxPlayers == 0 then
    return nil, nil, true -- ignore bogus LFR entries
  end
  if typeID == 1 and subtypeID == 5 and difficultyID == 14 and maxPlayers == 25 then
    return nil, nil, true -- ignore old Flex entries
  end

  -- missing required fields
  if not (lfgName and expansionLevel and recLevel) 
    -- or instance not a dungeon/raid/random-dungeon 
  or not hasValidTypeID()
  then 
    -- SI:Debug("invalid dungeon name %s | expansion %d | level %d| valid %s . Skipping!", lfgName or 'nil', expansionLevel or -1, recLevel or -1, tostring(hasValidTypeID()))
    return 
  end -- then invalid dunegon. ignore it.
  if lfgName:find(PVP_RATED_BATTLEGROUND) then return nil, nil, true end 
  -- ensure uniqueness (eg TeS LFR)
  if SI.LFRInstances[dungeonID] then 
    local lfrDungeonID =  SI.db.Instances[lfgName] and SI.db.Instances[lfgName].lfgDungeonID
    if lfrDungeonID and SI.LFRInstances[lfrDungeonID] then
      -- Clean LFR entry from `SI.db.Instances` table.
      -- should only exist in `SI.LFRInstances` 
      SI.db.Instances[lfgName] = nil 
    end
    SI.db.Instances[L["Flex"]..": "..lfgName] = nil -- clean old flex entries (should do this in db compatabiliy)
    lfgName = L["LFR"]..": "..lfgName
  end

  local lfgDungeonIdBlacklist = {
    [1966] = true, -- Arathi Basin Comp Stomp 
    [1661] = true, -- AI Test - Arathi Basin
    [1508] = true, -- AI Test - Warsong Gulch
    [1428] = true, -- Shado-Pan Showdown
    [767] = true, -- ignore bogus Ordos entry
    [768] = true, -- ignore bogus Celestials entry
  }  
  if lfgDungeonIdBlacklist[dungeonID] then return nil, nil, true end

  -- DEPRRACTED GetLFGDungeonInfo(852) returns nil now. This code would never execute.
  if dungeonID == 852 and expansionLevel == 5 then -- XXX: Molten Core hack
    return nil, nil, true -- ignore Molten Core holiday version, which has no save
  end

  ---@type SavedInstances.DB.Instance.Entry
  local instanceInfo = {
    LFDID = dungeonID,
    lfgDungeonID = dungeonID,
    Show = "saved",
    RecLevel = recLevel,
    Raid = (maxPlayers > 5 or (maxPlayers == 0 and typeID == 2)),
    Random = (typeID == TYPEID_RANDOM_DUNGEON),
    Holiday = isHoliday and true or false,
    Expansion = expansionLevel,
    WorldBoss = nil,
    Scenario = nil, -- or (subtypeID == LFG_SUBTYPEID_SCENARIO),
    encountersByDifficulty = {},
  }
  local isNewInstance = not SI.db.Instances[lfgName]
  if isNewInstance then
    SI:Debug("New Instance Inserted to DB: %s | expansion %s | recLevel %s", lfgName, expansionLevel, recLevel)
    SI.db.Instances[lfgName] = instanceInfo
  end

  -- the following code seems like it should be in the db compatability. Kept it coz unsure if its needed.
  -- Recomended levels for instances stored in saved variables should only be updated when there are level squishes or the dungeonID is changed.
  local savedInfo = SI.db.Instances[lfgName] 
  if not savedInfo.RecLevel or savedInfo.RecLevel < 1 then savedInfo.RecLevel = recLevel end
  if recLevel > 0 and recLevel < savedInfo.RecLevel then savedInfo.RecLevel = recLevel end -- favor non-heroic RecLevel (why do we care about rec level? for sorting the instances based on reccomended level)
  
  --upsert fields
  for field, value in pairs(instanceInfo) do
    if type(value) ~= nil 
      and (not savedInfo[field] or type(savedInfo[field] ~= type(value))) 
    then
      ---@diagnostic disable-next-line: assign-type-mismatch
      savedInfo[field] = value
    end
  end

  return lfgName, isNewInstance
end

---Update SavedInstancesScanTooltip with the debuff tooltip corresponding to the passed `spellID`
---@param spellID number spellID of the debuff to be displayed on tooltip.
function SI:updateSpellTip(spellID)
  local slot
  SI.db.spelltip = SI.db.spelltip or {}
  SI.db.spelltip[spellID] = SI.db.spelltip[spellID] or {}
  for i = 1, 255 do
    ---@type number 
    local id = select(10, UnitAura('player', i, 'HARMFUL'))
    if id == spellID then
      slot = i
      break
    end
  end
  if slot then
    SI.ScanTooltip:SetOwner(UIParent, 'ANCHOR_NONE')
    SI.ScanTooltip:SetUnitDebuff('player', slot)
    SI.ScanTooltip:Show()
    for i = 1, SI.ScanTooltip:NumLines() - 1 do
      ---@type FontString
      local textLeft = _G[SI.ScanTooltip:GetName() .. 'TextLeft' .. i]
      SI.db.spelltip[spellID][i] = textLeft:GetText()
    end
  end
end

--- Updates a variety of different saved variables for all characters.
--- Clears anything having to do with daily/weekly resets or random group finder cooldowns.
--- run regularly to update lockouts and cached data for *this* toon
function SI:UpdateToonData()
  local nextDailyReset = SI:GetNextDailyResetTime()
  local currentTimestamp = time()
  local instancesStore = SI.db.Instances

  -- blizz internally conflates all the holiday flags
  SI.activeHolidays = SI.activeHolidays and wipe(SI.activeHolidays) or {}

  -- cycle through que-able random dungeons and check if any are holiday dungeons
  for i = 1, GetNumRandomDungeons() do
    local lfgDungeonID, name = GetLFGRandomDungeonInfo(i)
    if name and lfgDungeonID 
    and instancesStore[name] 
    and instancesStore[name].Holiday 
    then
      -- id used in timewalking item quest, name used later this function
      SI.activeHolidays[lfgDungeonID] = true
      SI.activeHolidays[name] = true
    end
  end

  -- update expired instances for all toons and add any new lockouts for current toon.
  for instanceKey, instance in pairs(instancesStore) do

    -- Clean up **all** lockouts for all toons. 
    -- if the lockout is a random dungeon and has expired then remove its info table completely
    for toonName, _ in pairs(SI.db.Toons) do
      if instance[toonName] then
        for difficultyID, lockout in pairs(instance[toonName]) do
          -- lockout is assumed to be defined
          -- if lockout.Expires and lockout.Expires < time() then
          if time() >= lockout.Expires then
            lockout.Locked = false
            lockout.Expires = 0
            -- nil any entry thats a random dungeon daily lockout
            if lockout.ID < 0 then
              instance[toonName][difficultyID] = nil
            end
          end
        end
      end
    end

    -- Check current toon's completion status of daily incentive for holiday and random dungeons.
    -- (currently only tracking for the gold incentive and not currencies/items)
    if (instance.Holiday and SI.activeHolidays[instanceKey]) 
      or (not instance.Holiday and instance.Random) 
    then
      local dungeonID = instance.lfgDungeonID
      GetLFGDungeonInfo(dungeonID) -- forces update
      
      -- doneToday, moneyBase, moneyVar, experienceBase, experienceVar, numRewards
      ---@type boolean?, number?, any, any, any, number?
      local isDoneToday, goldReward, _, _, _, numRewards = GetLFGDungeonRewards(dungeonID) 
      local hasGoldReward = goldReward and goldReward > 0 or false
      -- for rewardIdx = 1, numRewards do -- to get non-gold rewards do something like this
      --   local name, texture, quantity, isBonusReward?, rewardObjectType, objectID, expansionLevel? = GetLFGDungeonRewardInfo(dungeonID, rewardIdx)
      -- end

      -- There some random dungeons where either, no daily incentive is available,
      -- or its' infinitely repeatable. In either case we want to set the `isDoneToday` flag to `false` for these.
      local hasRewardExecption = {
        [301] = true, -- Cata heroic
        [434] = true, -- Hour of Twilight
        [2447] = true, --  WotLK Random Heroic: Gamma
        [2470] = true, -- WotLK Random Heroic: Beta
        [2485] = true, -- WotLK Random Heroic: Alpha
      }
      if instance.Random and isDoneToday
        and hasRewardExecption[dungeonID]
      then 
        isDoneToday = false
      end

      -- If a random queue-able instance...
      if (instance.Holiday or hasGoldReward) -- has *daily* gold reward (or is a holdiay event) 
        and isDoneToday -- and has been completed by current charater
        and nextDailyReset -- and we have valid daily reset timestamp
      then -- track the lockout
        local difficultyID = 1

        -- incase table has not been created for character
        -- ideally should used a `__index` metamethod to create table on demand if not found.
        instance[SI.thisToon] = instance[SI.thisToon] or {}

        ---@type SavedInstances.DB.Instance.LockoutInfo
        instance[SI.thisToon][difficultyID] = instance[SI.thisToon][difficultyID] or {
            Expires = nextDailyReset,
            ID = -1, -- default lockoutID for dungeons not in `/raidinfo`
            Locked = true,
            Extended = nil, -- not used for Random Dungeon "lockout"
            Link = nil, -- same reason as above
        } 
      end
    end
  end

  local playerData = SI.db.Toons[SI.thisToon]
  
  
  -- The following should probably be done in a hookscript on `RequestTimePlayed()`
  -- and the function should be called whenever a refresh is required. 
  if SI.logout or SI.PlayedTime or SI.playedpending then
    if SI.PlayedTime then
      local additionalTime = currentTimestamp - SI.PlayedTime
      playerData.PlayedTotal = playerData.PlayedTotal + additionalTime
      playerData.PlayedLevel = playerData.PlayedLevel + additionalTime
      SI.PlayedTime = currentTimestamp
    end
  else
    SI.playedpending = true
    -- use an empty table
    SI.playedreg = SI.playedreg and wipe(SI.playedreg) or {}

    -- Unregister all chat frames from `TIME_PLAYED_MSG` event so that user does not see `/played` message
    -- whenever a refresh is done using `RequestTimePlayed()`.
    for i=1,10 do
      local c = _G["ChatFrame"..i]
      if c and c:IsEventRegistered("TIME_PLAYED_MSG") then
        c:UnregisterEvent("TIME_PLAYED_MSG") -- prevent spam
        SI.playedreg[c] = true
      end
    end
    RequestTimePlayed()
  end

  -- update the random dunegon cooldowns (queue cooldown and deserter debuff)
  playerData.LFG1 = SI:SystemTimeToUnix(GetLFGRandomCooldownExpiration()) or playerData.LFG1
  playerData.LFG2 = SI:SystemTimeToUnix(SI:GetPlayerAuraExpirationTime(71041)) or playerData.LFG2 -- GetLFGDeserterExpiration()
  playerData.pvpdesert = SI:SystemTimeToUnix(SI:GetPlayerAuraExpirationTime(26013)) or playerData.pvpdesert
  
  -- if toon has either derserter (pve or pvp) add it to the spelltip cache
  if playerData.LFG2 then SI:updateSpellTip(71041) end
  if playerData.pvpdesert then SI:updateSpellTip(26013) end
  
  -- clean up stale timer states for ALL toons 
  for toon, toonData in pairs(SI.db.Toons) do
    if toonData.LFG1 and (toonData.LFG1 < currentTimestamp) then toonData.LFG1 = nil end
    if toonData.LFG2 and (toonData.LFG2 < currentTimestamp) then toonData.LFG2 = nil end
    if toonData.pvpdesert and (toonData.pvpdesert < currentTimestamp) then toonData.pvpdesert = nil end

    -- this table should be created when the toonData for this toon is initialzied instead. 
    -- toonData.Quests = toonData.Quests or {}
  end

  ---@type number?, number?, number?
  local maxItemLevel, equippedItemLevel, pvpItemLevel = GetAverageItemLevel()
  if maxItemLevel then -- API can fail during logout requiring nil check
    maxItemLevel = tonumber(maxItemLevel) -- not sure why author converts to number here
    if maxItemLevel > 0 then
      playerData.IL, playerData.ILe = maxItemLevel, tonumber(equippedItemLevel)
    end
  end
  if pvpItemLevel and tonumber(pvpItemLevel) > 0 then
    playerData.ILPvp = tonumber(pvpItemLevel)
  end
  if not SI.isClassicEra then
    -- Not sure what reason for parsing, what should be a base 10 number, into a base 10 number is. 
    -- Keep it assuming its related to some bug. 
    playerData.Arena2v2rating = GetPersonalRatedInfo(1) or playerData.Arena2v2rating
    playerData.Arena3v3rating = GetPersonalRatedInfo(2) or playerData.Arena3v3rating
    if SI.isRetail then
      playerData.RBGrating = GetPersonalRatedInfo(4) or playerData.RBGrating
    end
  end
  playerData.SpecializationIDs = playerData.SpecializationIDs or {}
  for i = 1, GetNumSpecializations() do
    playerData.SpecializationIDs[i] = GetSpecializationInfo(i) or playerData.SpecializationIDs[i]
  end

  if SI.isRetail then
    -- Solo Shuffle rating is unique to each specialization
    playerData.SoloShuffleRating = playerData.SoloShuffleRating or {}
    local currentSpecID = GetSpecialization()
    if currentSpecID then
      playerData.SoloShuffleRating[currentSpecID] = GetPersonalRatedInfo(7) or playerData.SoloShuffleRating[currentSpecID]
    end
  end

  TradeSkill:ScanPlayerItemCooldowns()

  -- On Daily Reset
  if nextDailyReset and nextDailyReset > currentTimestamp then
    -- account daily clean up on new days
    if playerData.DailyResetTime < currentTimestamp then
      for id, quest in pairs(SI.db.Quests) do
        if quest.isDaily then
          SI.db.Quests[id] = nil
        end
      end
      -- current character data will reset in the following loop through all characters.
      -- playerData.DailyResetTime = nextDailyReset
    end
    -- cleanup normal dailies for all characters, and catchup their reset timer.
    for name, toonData in pairs(SI.db.Toons) do
      if not toonData.DailyResetTime or (toonData.DailyResetTime < currentTimestamp) then
        for id,quest in pairs(toonData.Quests) do
          if quest.isDaily then
            toonData.Quests[id] = nil
          end
        end
        Progress:OnDailyReset(name)
        toonData.DailyResetTime = (toonData.DailyResetTime and toonData.DailyResetTime + 24*3600) or nextDailyReset
      end
    end
    ---@todo type out `Calling`
    ---@diagnostic disable-next-line: undefined-field 
    if SI.isRetail and Calling then Calling:OnDailyReset() end

    -- Emissary Quest Reset
    if SI.db.Emissary and SI.db.Emissary.Expansion then
      local expansionLevel, tbl
      for expansionLevel, tbl in pairs(SI.db.Emissary.Expansion) do
        while tbl[1] and tbl[1].expiredTime < time() do
          tbl[1] = tbl[2]
          tbl[2] = tbl[3]
          tbl[3] = nil
          for toon, ti in pairs(SI.db.Toons) do
            if ti.Emissary then
              local t = ti.Emissary[expansionLevel]
              if t and t.unlocked then
                t.days[1] = t.days[2]
                t.days[2] = t.days[3]
                t.days[3] = {
                  isComplete = false,
                  isFinish = false,
                  questDone = 0,
                }
              end
            end
          end
        end
      end
    end
  end
  -- Clear expired non-daily quests for all toons
  for _, toonData in pairs(SI.db.Toons) do
    for id,quest in pairs(toonData.Quests) do
      if not quest.isDaily and (quest.Expires or 0) < currentTimestamp then
        if SI.db.QuestDB.Darkmoon[id] then
          SI:Debug("clearing up expried DMF quest: %s [%i] |n character: %s | expired: %s", quest.Title, id, _, date("%c", quest.Expires));
        end
        toonData.Quests[id] = nil
      end
      if QuestExceptions[id] == "Regular" then -- adjust exceptions
        toonData.Quests[id] = nil
      end
    end
  end
  -- Clear expired non-daily account-wide quests
  for id, quest in pairs(SI.db.Quests) do -- AccountWeekly reset
    if not quest.isDaily and (quest.Expires or 0) < currentTimestamp then
      SI.db.Quests[id] = nil
    end
  end

  -- Weekly Resets
  local nextWeeklyReset = SI:GetNextWeeklyResetTime()
  if nextWeeklyReset > currentTimestamp then
    for toonName, toonData in pairs(SI.db.Toons) do
      if not toonData.WeeklyResetTime or (toonData.WeeklyResetTime < currentTimestamp ) then
        for _, currencyID in ipairs(Currency:GetCurrencyList()) do
          assert(toonData.currency, "toonData.currency is nil")
          local currency = toonData.currency[currencyID]
          if currency and currency.earnedThisWeek then
            currency.earnedThisWeek = 0
          end
        end
        Progress:OnWeeklyReset(toonName)
        toonData.WeeklyResetTime = nextWeeklyReset 
          -- or (toonData.WeeklyResetTime + 7*24*3600) *shouldnt fail*
      end
    end
    playerData.WeeklyResetTime = nextWeeklyReset
  end

  -- Skill Resets
  for toon, toonData in pairs(SI.db.Toons) do
    if toonData.Skills then
      for spellID, spellInfo in pairs(toonData.Skills) do
        if spellInfo.Expires and spellInfo.Expires < currentTimestamp then
          toonData.Skills[spellID] = nil
        end
      end
    end
  end
  -- Mythic+ Keystone weekly reset for all toons
  for toon, toonData in pairs(SI.db.Toons) do
    if toonData.MythicKey and (toonData.MythicKey.ResetTime or 0) < currentTimestamp then
      toonData.MythicKey = {}
    end
  end
  -- Timeworn Mythic+ Keystone weekly reset for all toons
  for toon, toonData in pairs(SI.db.Toons) do
    if toonData.TimewornMythicKey and (toonData.TimewornMythicKey.ResetTime or 0) < currentTimestamp then
      toonData.TimewornMythicKey = {}
    end
  end
  -- Mythic+ weekly best reset for all toons
  for toon, toonData in pairs(SI.db.Toons) do
    if toonData.MythicKeyBest and (toonData.MythicKeyBest.ResetTime or 0) < currentTimestamp then
      toonData.MythicKeyBest.rewardWaiting = toonData.MythicKeyBest.lastCompletedIndex and toonData.MythicKeyBest.lastCompletedIndex > 0
      toonData.MythicKeyBest[1] = nil
      toonData.MythicKeyBest[2] = nil
      toonData.MythicKeyBest[3] = nil
      toonData.MythicKeyBest.lastCompletedIndex = nil
      toonData.MythicKeyBest.runHistory = nil
      toonData.MythicKeyBest.ResetTime = SI:GetNextWeeklyResetTime()
    end
  end

  ---@diagnostic disable-next-line: undefined-field
  if Calling then Calling:PostRefresh() end

  Currency:UpdatePlayerCurrencies()

  local zone = GetRealZoneText()
  if zone and #zone > 0 then
    playerData.Zone = zone
  end
  playerData.Level = UnitLevel("player")
  local lrace, race = UnitRace("player")
  local faction, lfaction = UnitFactionGroup("player")
  playerData.Faction = faction
  playerData.oRace = race
  if race == "Pandaren" then
    playerData.Race = lrace.." ("..lfaction..")"
  else
    playerData.Race = lrace
  end

  if not SI.logout then -- isLoggingOut?
    playerData.isResting = IsResting()
    playerData.MaxXP = UnitXPMax("player")
    if playerData.Level < SI.maxLevel then
      playerData.XP = UnitXP("player")
      playerData.RestXP = GetXPExhaustion()
    else
      playerData.XP = nil
      playerData.RestXP = nil
    end
    playerData.Warmode = SI.isRetail and C_PvP.IsWarModeDesired() or nil
    playerData.Covenant = SI.isRetail and C_Covenants.GetActiveCovenantID() or nil
    playerData.MythicPlusScore = SI.isRetail and C_ChallengeMode.GetOverallDungeonScore() or nil
  end

  playerData.LastSeen = currentTimestamp
end

---@return boolean isDMFMonthly `true` is the currently viewed quest (from a quest giver) is a DMF monthly
function SI:QuestIsDarkmoonMonthly()
    if QuestIsDaily() then return false end
    local id = GetQuestID()
    local DARKMOON_TICKET_TEXTURE = 134481
    local questType = id and QuestExceptions[id]
    if questType and questType ~= "Darkmoon" then return false end -- one-time referral quests
    for i = 1, GetNumRewardCurrencies() do
        local _, texture, _ = GetQuestCurrencyInfo("reward", i)
        if texture == DARKMOON_TICKET_TEXTURE then
            return true
        end
    end
    return false
end

-- The `QuestIsWeekly` API function is not in the WoTLK/Era client (yet)
-- luckily theres only a limited amount of weeklies so this is a viable workaround
local QuestIsWeekly = QuestIsWeekly or function()
  local id = GetQuestID()
  if not id then return end -- i think `GetQuestID()` will return 0 instead of nil 
  if SI.isCataclysm then
    local wrathWeeklies = {
      [24579] = true, -- Sartharion Must Die!
      [24580] = true, -- Anub'Rekhan Must Die!
      [24581] = true, -- Noth the Plaguebringer Must Die!
      [24582] = true, -- Instructor Razuvious Must Die!
      [24583] = true, -- Patchwerk Must Die!
      [24584] = true, -- Malygos Must Die!
      [24585] = true, -- Flame Leviathan Must Die!
      [24586] = true, -- Razorscale Must Die!
      [24587] = true, -- Ignis the Furnace Master Must Die!
      [24588] = true, -- XT-002 Deconstructor Must Die!
      [24590] = true, -- Lord Marrowgar Must Die!
      -- Aliance ICC Weekly
      [24871] = true, -- Securing the Ramparts (10)
      [24876] = true, -- Securing the Ramparts (25)
      -- Horde ICC Weekly
      [24870] = true, -- Securing the Ramparts (10)
      [24877] = true, -- Securing the Ramparts (25)
      -- Shared ICC Weekly
      [24869] = true, -- Deprogramming (10)
      [24875] = true, -- Deprogramming (25)
      [24872] = true, -- Respite for a Tormented Soul (10)
      [24880] = true, -- Respite for a Tormented Soul (25)
      [24873] = true, -- Residue Rendezvous (10)
      [24878] = true, -- Residue Rendezvous (25)
      [24874] = true, -- Blood Quickening (10)
      [24879] = true, -- Blood Quickening (25)
    }
    return wrathWeeklies[id] or false
  elseif SI.isSoD then 
    local sodWeeklies = {
      [79090] = false, -- Repelling Invaders (changed to daily)
      [79098] = false -- Clear the Forest (changed to daily)
    }
    return sodWeeklies[id] or false
  end
end


--- Parses the recently turned-in quest and updates the `SI.db` accordingly with the quest .
local function SI_OnQuestComplete()
  --- bug: restedXP (and mayber other addons too) can call the `GetQuestReward` function
  --- we chould check to see if the quest frame was actually open with `GetQuestID() ~= 0`
  if GetQuestID() == 0 then return end

  local toonData = SI and SI.db.Toons[SI.thisToon]
  if not toonData then return end

  local questID = GetQuestID() or -1
  local questLink = GetQuestLink(questID)
  local questTitle = GetTitleText() or ""
  local isMonthly = SI:QuestIsDarkmoonMonthly()
  local isWeekly = QuestIsWeekly()
  local isDaily = QuestIsDaily()
  local isAccount = C_QuestLog.IsAccountQuest and C_QuestLog.IsAccountQuest(questID) or nil

  if questID > 1 then -- try harder to fetch names
    local questName, _questLink = SI:QuestInfo(questID)
    if not (questLink and #questLink > 0) then
      questLink = _questLink
    end
    if not (questTitle and #questTitle > 0) then
      questTitle = questName or "<unknown>"
    end
  end

  if QuestExceptions[questID] then
    local exception = QuestExceptions[questID]
    isAccount = exception:find("Account") and true or false
    isDaily = exception:find("Daily") and true or false
    isWeekly = 	exception:find("Weekly") and true or false
    isMonthly =	exception:find("Darkmoon") and true or false
  end

  local expires

  --- A Sub table of `SI.db.QuestDB` appropriate for current quest.
  --- Either, `Daily | Weekly | AccountDaily | AccountWeekly | Darkmoon`
  local propperQuestDB
  if isWeekly then
    expires = SI:GetNextWeeklyResetTime()
    propperQuestDB = (isAccount and SI.db.QuestDB.AccountWeekly) or SI.db.QuestDB.Weekly
  elseif isMonthly then
    expires = SI:GetNextDarkmoonFaireEnd()
    propperQuestDB = SI.db.QuestDB.Darkmoon
  elseif isDaily then
    propperQuestDB = (isAccount and SI.db.QuestDB.AccountDaily) or SI.db.QuestDB.Daily
    -- Dailies are reset on new days instead of an expiry timestamp.
    -- expires = SI:GetNextDailyResetTime()
  end

  SI:Debug("Quest Complete: "..(questLink or questTitle).." "..questID.." : "..questTitle.." "..
  (isAccount and "(Account) " or "")..
  (isMonthly and "(Monthly)" or isWeekly and "(Weekly)" or isDaily and "(Daily)" or "(Regular)").."  "..
  (expires and date("%c",expires) or ""))

  if not isMonthly and not isWeekly and not isDaily then return end

  local mapID = SI:GetCurrentMapAreaID()
  propperQuestDB[questID] = mapID

  ---@type SavedInstances.Toon.Quest
  local questInfo =  { 
    ["Title"] = questTitle, 
    ["Link"] = questLink,
    ["isDaily"] = isDaily,
    ["Expires"] = expires,
    ["Zone"] = C_Map.GetMapInfo(mapID) 
  }
  --- will use the `SI.db` instead of `toonData` if `isAccount` is true
  ---@type SavedInstances.Toon | SavedInstances.DB
  local toonOrAccountData = toonData
  if isAccount then
    toonOrAccountData = SI.db
    -- stop tracking quest for speficic toon since it will now be tracked account wide.
    if toonData.Quests then toonData.Quests[questID] = nil end -- make sure we promote account quests
  end

  toonOrAccountData.Quests = toonOrAccountData.Quests or {}
  toonOrAccountData.Quests[questID] = questInfo

  -- Get completed counts for debug output.
  local toonDailies, toonWeeklies = SI:QuestCount(SI.thisToon)
  local accountDailies, accountWeeklies = SI:QuestCount(nil)
  SI:Debug("DailyCount: "..toonDailies..
    "  WeeklyCount: "..toonWeeklies..
    "  AccountDailyCount: "..accountDailies..
    "  AccountWeeklyCount: "..accountWeeklies
  )
end
hooksecurefunc("GetQuestReward", SI_OnQuestComplete)

local function coloredText(fontstring)
  if not fontstring then return nil end
  local text = fontstring:GetText()
  if not text then return nil end
  local textR, textG, textB, textAlpha = fontstring:GetTextColor()
  return string.format("|c%02x%02x%02x%02x"..text.."|r",
    textAlpha*255, textR*255, textG*255, textB*255)
end

-- Hover Tooltips
local hoverTooltip = {}
SI.hoverTooltip = hoverTooltip

hoverTooltip.ShowToonTooltip = function (cell, arg, ...)
  local toon = arg
  if not toon then return end
  local t = SI.db.Toons[toon]
  if not t then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  local ftex = ""
  if t.Faction == "Alliance" then
    ftex = "\124TInterface\\TargetingFrame\\UI-PVP-Alliance:0:0:0:0:100:100:0:50:0:55\124t "
  elseif t.Faction == "Horde" then
    ftex = "\124TInterface\\TargetingFrame\\UI-PVP-Horde:0:0:0:0:100:100:10:70:0:55\124t"
  end
  indicatortip:SetCell(indicatortip:AddHeader(),1,ftex..ClassColorise(t.Class, toon))
  indicatortip:SetCell(1,2,ClassColorise(t.Class, LEVEL.." "..t.Level.." "..(t.LClass or "")))
  if t.Level < SI.maxLevel and t.XP then
    local restXP = (t.RestXP or 0) + (t.MaxXP / 20) * ((time() - t.LastSeen) / (3600 * (t.isResting and 8 or 32)))
    local percent = min(floor(restXP / t.MaxXP * 100), 150) * (t.oRace == "Pandaren" and 2 or 1)
    indicatortip:AddLine(COMBAT_XP_GAIN, format("%.0f%% + %.0f%%", t.XP / t.MaxXP * 100, percent))
  end
  indicatortip:AddLine(STAT_AVERAGE_ITEM_LEVEL,("%d "):format(t.IL or 0)..STAT_AVERAGE_ITEM_LEVEL_EQUIPPED:format(t.ILe or 0))
  indicatortip:AddLine(LFG_LIST_ITEM_LEVEL_INSTR_PVP_SHORT,("%d"):format(t.ILPvp or 0))
  if t.Covenant and t.Covenant > 0 then
    assert(SI.isRetail, "Covenant data is only available in retail")
    local data = C_Covenants.GetCovenantData(t.Covenant)
    local name = data and data.name
    if name then
      indicatortip:AddLine(L["Covenant"], name)
    end
  end
  if t.MythicPlusScore and t.MythicPlusScore > 0 then
    indicatortip:AddLine(DUNGEON_SCORE, t.MythicPlusScore)
  end
  if t.Arena2v2rating and t.Arena2v2rating > 0 then
    indicatortip:AddLine(ARENA_2V2 .. ARENA_RATING, t.Arena2v2rating)
  end
  if t.Arena3v3rating and t.Arena3v3rating > 0 then
    indicatortip:AddLine(ARENA_3V3 .. ARENA_RATING, t.Arena3v3rating)
  end
  if t.RBGrating and t.RBGrating > 0 then
    indicatortip:AddLine(BG_RATING_ABBR, t.RBGrating)
  end
  if t.SoloShuffleRating and t.SpecializationIDs then
    for i, specID in ipairs(t.SpecializationIDs) do
      if t.SoloShuffleRating[i] and t.SoloShuffleRating[i] > 0 then
        local _, specName = GetSpecializationInfoForSpecID(specID)
        indicatortip:AddLine(PVP_RATED_SOLO_SHUFFLE .. " " .. RATING .. ": " .. specName, t.SoloShuffleRating[i])
      end
    end
  end
  if t.Money then
    indicatortip:AddLine(MONEY,SI:formatNumber(t.Money,true))
  end
  if t.Warmode and t.Warmode == true then
    indicatortip:AddLine(PVP_LABEL_WAR_MODE, PVP_WAR_MODE_ENABLED)
  end
  if t.Zone then
    indicatortip:AddLine(ZONE,t.Zone)
  end
  --[[
  if t.Race then
  indicatortip:AddLine(RACE,t.Race)
  end
  ]]
  if t.LastSeen then
    local when = date("%c",t.LastSeen)
    indicatortip:AddLine(L["Last updated"],when)
  end
  if SI.db.Tooltip.TrackPlayed and t.PlayedTotal and t.PlayedLevel and ChatFrame_TimeBreakDown then
    --indicatortip:AddLine((TIME_PLAYED_TOTAL):format((TIME_DAYHOURMINUTESECOND):format(ChatFrame_TimeBreakDown(t.PlayedTotal))))
    --indicatortip:AddLine((TIME_PLAYED_LEVEL):format((TIME_DAYHOURMINUTESECOND):format(ChatFrame_TimeBreakDown(t.PlayedLevel))))
    indicatortip:AddLine((TIME_PLAYED_TOTAL):format(""),SecondsToTime(t.PlayedTotal))
    indicatortip:AddLine((TIME_PLAYED_LEVEL):format(""),SecondsToTime(t.PlayedLevel))
  end
  indicatortip:Show()
end

hoverTooltip.ShowQuestTooltip = function (cell, arg, ...)
  local toonFullName, questCount, type = unpack(arg)
  local isDaily = type == "daily"
  local isDMF = type == "Darkmoon"

  local displayStr = isDMF and L["Darkmoon Quests"]
    or (isDaily and L["Daily Quests"] or L["Weekly Quests"]);
  displayStr = questCount..' '.. displayStr -- prepend quest count
  
  ---@type SavedInstances.Toon | SavedInstances.DB
  local targetDB = SI.db
  local scopeStr = L["Account"]
  local reset
  if toonFullName then
    targetDB = SI.db.Toons[toonFullName]
    if not targetDB then return end
    scopeStr = ClassColorise(targetDB.Class, toonFullName)
    reset = (isDaily and targetDB.DailyResetTime) -- Prio is Daily > DMF (since they have dailies too) > Weekly
      or (isDMF and SI:GetNextDarkmoonFaireEnd())
      or (not isDaily and targetDB.WeeklyResetTime)
  end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  indicatortip:AddHeader(scopeStr, displayStr)
  if not reset then
    reset = (isDaily and SI:GetNextDailyResetTime()) or (not isDaily and SI:GetNextWeeklyResetTime())
  end
  if reset then
    indicatortip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Time Left"] .. ":"),
      SecondsToTime(reset - time()))
  end
  local questsByZoneKey = {} -- groups quests by zone, to be sorted.
  local zonename, id
  for id, questInfo in pairs(targetDB.Quests) do
    if (not isDaily) == (not questInfo.isDaily) then
      if not SI:QuestIgnored(id)
      -- only show darkmoon quest in character specific darkmoon categories
      and (not (QuestExceptions[id] == "Darkmoon") or isDMF)
      then
        zonename = questInfo.Zone and questInfo.Zone.name or ""
        table.insert(questsByZoneKey,zonename.." # "..id)
      end
    end
  end
  table.sort(questsByZoneKey)
  for _, key in ipairs(questsByZoneKey) do
    zonename, id = key:match("(.*) # (%d+)")
    id = tonumber(id)
    local questInfo = targetDB.Quests[id]
    local line = indicatortip:AddLine()
    local link = questInfo.Link
    if not link then -- sometimes missing the actual link due to races, fake it for display to prevent confusion
      if questInfo.Title and questInfo.Title:find("("..LOOT..")") then
        link = questInfo.Title
      else
        link = "\124cffffff00["..(questInfo.Title or "???").."]\124r"
      end
    end
    -- Exception: Some quests should not show zone name, such as Blingtron
    if (id == 31752 or id == 34774 or id == 40753 or id == 56042) then
      zonename = ""
    end
    indicatortip:SetCell(line,1,zonename,nil,"LEFT")
    indicatortip:SetCell(line,2,link,nil,"RIGHT")
  end
  indicatortip:Show()
end

hoverTooltip.ShowSkillTooltip = function (cell, arg, ...)
  local toon, cnt = unpack(arg)
  local cstr = cnt.." "..L["Trade Skill Cooldowns"]
  local t = SI.db.Toons[toon]
  if not t then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(3, "LEFT","RIGHT","RIGHT")
  local tname = ClassColorise(t.Class, toon)
  indicatortip:AddHeader()
  indicatortip:SetCell(1,1,tname,nil,"LEFT")
  indicatortip:SetCell(1,2,cstr,nil,"RIGHT",2)

  local tmp = {}
  for _,sinfo in pairs(t.Skills) do
    table.insert(tmp,sinfo)
  end
  table.sort(tmp, function (s1, s2)
    if s1.Expires ~= s2.Expires then
      return (s1.Expires or 0) < (s2.Expires or 0)
    else
      return (s1.Title or "") < (s2.Title or "")
    end
  end)

  for _,sinfo in ipairs(tmp) do
    local line = indicatortip:AddLine()
    local title = sinfo.Link or sinfo.Title or "???"
    local tstr = SecondsToTime((sinfo.Expires or 0) - time())
    indicatortip:SetCell(line,1,title,nil,"LEFT",2)
    indicatortip:SetCell(line,3,tstr,nil,"RIGHT")
  end
  indicatortip:Show()
end

hoverTooltip.ShowEmissarySummary = function (cell, arg, ...)
  local expansionLevel, days = unpack(arg)
  local day
  local first = true
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT", "RIGHT")
  for _, day in pairs(days) do
    if first == false then
      indicatortip:AddSeparator(6,0,0,0,0)
    end
    first = false
    indicatortip:AddHeader(L["Emissary quests"], "+" .. (day - 1) .. " " .. L["Day"])
    local tbl = {}
    local toon, t
    for toon, t in pairs(SI.db.Toons) do
      local info = (
        t.Emissary and t.Emissary[expansionLevel] and
        t.Emissary[expansionLevel].days and t.Emissary[expansionLevel].days[day]
      )
      if info then
        tbl[t.Faction] = true
      end
    end
    if (not tbl.Alliance and not tbl.Horde) or (not SI.db.Emissary.Expansion[expansionLevel][day]) then
      indicatortip:AddLine(L["Emissary Missing"], "")
    else
      local globalInfo = SI.db.Emissary.Expansion[expansionLevel][day]
      local merge = (globalInfo.questID.Alliance == globalInfo.questID.Horde) and true or false
      local header = false
      for fac, _ in pairs(tbl) do
        if merge == false then header = false end
        for toon, t in pairs(SI.db.Toons) do
          if t.Faction == fac then
            local info = (
              t.Emissary and t.Emissary[expansionLevel] and
              t.Emissary[expansionLevel].days and t.Emissary[expansionLevel].days[day]
            )
            if info then
              if header == false then
                local name = SI.db.Emissary.Cache[globalInfo.questID[fac]]
                if not name then
                  name = L["Emissary Missing"]
                end
                indicatortip:AddLine(name)
                header = true
              end
              local text
              if info.isComplete == true then
                text = SI.questCheckMark
              elseif info.isFinish == true then
                text = SI.questTurnin
              else
                text = info.questDone
                if globalInfo.questNeed then
                  text = text .. "/" .. globalInfo.questNeed
                end
              end
              indicatortip:AddLine(ClassColorise(t.Class, toon), text)
            end
          end
        end
      end
    end
  end
  indicatortip:Show()
end

hoverTooltip.ShowEmissaryTooltip = function (cell, arg, ...)
  local expansionLevel, day, toon = unpack(arg)
  local info = SI.db.Toons[toon].Emissary[expansionLevel].days[day]
  if not info then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT", "RIGHT")
  local globalInfo = SI.db.Emissary.Expansion[expansionLevel][day] or {}
  local text
  if info.isComplete == true then
    text = SI.questCheckMark
  elseif info.isFinish == true then
    text = SI.questTurnin
  else
    text = info.questDone
    if globalInfo.questNeed then
      text = text .. "/" .. globalInfo.questNeed
    end
  end
  indicatortip:AddLine(ClassColorise(SI.db.Toons[toon].Class, toon), text)
  text = (
    globalInfo.questID and SI.db.Emissary.Cache[globalInfo.questID[SI.db.Toons[toon].Faction]]
  ) or L["Emissary Missing"]
  indicatortip:AddLine()
  indicatortip:SetCell(2, 1, text,nil, "LEFT", 2)
  if info.questReward then
    text = ""
    if info.questReward.itemName then
      text = "|c" .. select(4, GetItemQualityColor(info.questReward.quality)) ..
            "[" .. info.questReward.itemName .. "(" .. info.questReward.itemLvl .. ")]" .. FONTEND
    elseif info.questReward.money then
      text = GetMoneyString(info.questReward.money)
    elseif info.questReward.currencyID then
      local data = C_CurrencyInfo.GetCurrencyInfo(info.questReward.currencyID)
      local iconID = Currency.OverrideTexture[info.questReward.currencyID] or data.iconFileID
      text = "\124T" .. iconID .. ":0\124t " .. info.questReward.quantity
    end
    indicatortip:AddLine()
    indicatortip:SetCell(3, 1, text,nil, "RIGHT", 2)
  end
  indicatortip:Show()
end

hoverTooltip.ShowCallingTooltip = function (cell, arg, ...)
  local day, toon = unpack(arg)
  local info = SI.db.Toons[toon].Calling[day]
  if not info then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT", "RIGHT")
  local text
  if info.isCompleted == true then
    text = SI.questCheckMark
  elseif not info.isOnQuest then
    text = SI.questNormal
  elseif info.isFinished == true then
    text = SI.questTurnin
  else
    if info.objectiveType == 'progressbar' then
      text = floor(info.questDone / info.questNeed * 100) .. "%"
    else
      text = info.questDone .. '/' .. info.questNeed
    end
  end
  indicatortip:AddLine(ClassColorise(SI.db.Toons[toon].Class, toon), text)
  indicatortip:AddLine()
  text = info.title
  if not text then
    for _, t in pairs(SI.db.Toons) do
      if t.Calling and t.Calling[day] and t.Calling[day].title then
        text = t.Calling[day].title
        break
      end
    end
  end
  indicatortip:SetCell(2, 1, text or L["Calling Missing"],nil, "LEFT", 2)
  if info.questReward and info.questReward.itemName then
    text = "|c" .. select(4, GetItemQualityColor(info.questReward.quality)) ..
           "[" .. info.questReward.itemName .. "]" .. FONTEND
    indicatortip:AddLine()
    indicatortip:SetCell(3, 1, text, nil, "RIGHT", 2)
  end
  indicatortip:Show()
end

hoverTooltip.ShowParagonTooltip = function (cell, arg, ...)
  local toon = arg
  local t = SI.db.Toons[toon]
  if not t or not t.Paragon then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT", "RIGHT")
  indicatortip:AddHeader(ClassColorise(t.Class, toon), #t.Paragon)
  for k, v in pairs(t.Paragon) do
    local name = GetFactionInfoByID(v)
    indicatortip:AddLine()
    indicatortip:SetCell(k + 1, 1, name, nil,"RIGHT", 2)
  end
  indicatortip:Show()
end

hoverTooltip.ShowMythicPlusTooltip = function (cell, arg, ...)
  local toon, keydesc = unpack(arg)
  local t = SI.db.Toons[toon]
  if not t or not t.MythicKeyBest then
    return
  end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT", "RIGHT")
  local text = keydesc or ""
  indicatortip:AddHeader(ClassColorise(t.Class, toon), text)
  if t.MythicKeyBest.runHistory and #t.MythicKeyBest.runHistory > 0 then
    local maxThreshold = t.MythicKeyBest.threshold and t.MythicKeyBest.threshold[#t.MythicKeyBest.threshold]
    local displayNumber = min(#t.MythicKeyBest.runHistory, maxThreshold or 8)
    indicatortip:AddLine()
    indicatortip:SetCell(2, 1, format(WEEKLY_REWARDS_MYTHIC_TOP_RUNS, displayNumber),nil, "LEFT", 2)
    indicatortip:AddLine()
    indicatortip:SetCell(3, 1, format(TOTAL_STACKS, #t.MythicKeyBest.runHistory),nil, "LEFT", 2)
    for i = 1, displayNumber do
      local runInfo = t.MythicKeyBest.runHistory[i]
      if runInfo.level and runInfo.name and runInfo.rewardLevel then
        indicatortip:AddLine()
        text = string.format("(%3$d) %1$d - %2$s", runInfo.level, runInfo.name, runInfo.rewardLevel)
        -- these are the thresholds that will populate the great vault
        if t.MythicKeyBest.threshold and tContains(t.MythicKeyBest.threshold, i) then
          text = GREEN:WrapTextInColorCode(text)
        end
        indicatortip:SetCell(2 + i, 1, text, nil,"LEFT", 2)
      end
    end
  end
  indicatortip:Show()
end

hoverTooltip.ShowBonusTooltip = function (cell, arg, ...)
  local toon = arg
  local parent
  if type(toon) == "table" then
    toon, parent = unpack(toon)
  end
  local t = SI.db.Toons[toon]
  if not t or not t.BonusRoll then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(4, "LEFT","LEFT","LEFT","LEFT")
  if parent then
    indicatortip:SetAutoHideDelay(0.1, parent)
    indicatortip:SmartAnchorTo(parent)
  end
  local tname = ClassColorise(t.Class, toon)
  indicatortip:AddHeader()
  indicatortip:SetCell(1,1,tname,nil,"LEFT",2)
  indicatortip:SetCell(1,3,L["Recent Bonus Rolls"],nil,"RIGHT",2)

  local line = indicatortip:AddLine()
  local lastWeeklyReset = SI:GetNextWeeklyResetTime(-1)
  local lastWeeklyRollIdx = 0
  for _, roll in ipairs(t.BonusRoll) do
    if roll.time and roll.time >= lastWeeklyReset then
      lastWeeklyRollIdx = lastWeeklyRollIdx + 1
    else
      break;
    end
  end
  local seperateWeeklyRolls = lastWeeklyRollIdx > 0
  if seperateWeeklyRolls then
    indicatortip:SetCell(line, 1, GUILD_CHALLENGES_THIS_WEEK, nil, "LEFT", 2)
  end
  for i,roll in ipairs(t.BonusRoll) do
    if i > 10 then break end
    local line = indicatortip:AddLine()
    if seperateWeeklyRolls and i == lastWeeklyRollIdx + 1 then
      indicatortip:SetCell(line, 1, PREVIOUS, nil, "LEFT", 2)
      line = indicatortip:AddLine()
    end
    local icon = roll.costCurrencyID and (Currency.OverrideTexture[roll.costCurrencyID] or C_CurrencyInfo.GetCurrencyInfo(roll.costCurrencyID).iconFileID)
    if icon then
      indicatortip:SetCell(line,1, " \124T"..icon..":0\124t ")
    end
    if roll.name then
      indicatortip:SetCell(line,2,roll.name)
    end
    if roll.item then
      indicatortip:SetCell(line,3,roll.item)
    elseif roll.currencyID then
      local data = C_CurrencyInfo.GetCurrencyInfo(roll.currencyID)
      local currencyIcon = Currency.OverrideTexture[roll.currencyID] or data.iconFileID
      local str = "\124T" .. currencyIcon .. ":0\124t "
      if roll.money then
        str = str .. roll.money
      else
        str = str .. data.name
      end
      indicatortip:SetCell(line,3,str)
    elseif roll.money then
      indicatortip:SetCell(line,3,GetMoneyString(roll.money))
    end
    if roll.time then
      indicatortip:SetCell(line,4,date("%b %d %H:%M",roll.time))
    end
  end
  indicatortip:Show()
end

hoverTooltip.ShowAccountSummary = function (cell, arg, ...)
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  indicatortip:SetCell(indicatortip:AddHeader(),1,GOLD:WrapTextInColorCode(L["Account Summary"]),
  nil,"LEFT",2)

  local totalMoney = 0
  local totalTime = 0
  local totalToons = 0
  local cappedToons = 0
  local allRealmInfo = {}

  -- Gather money info for all realms and their characters.w
  for toon, toonData in pairs(SI.db.Toons) do 
    local realm = toon:match(" %- (.+)$")
    local money = toonData.Money or 0
    totalMoney = totalMoney + money
    local realmInfo = allRealmInfo[realm] 
      or { ["realm"] = realm, ["money"] = 0, ["cnt"] = 0 }
    realmInfo.money = realmInfo.money + money
    realmInfo.cnt = realmInfo.cnt + 1
    allRealmInfo[realm] = realmInfo
    totalTime = totalTime + (toonData.PlayedTotal or 0)
    totalToons = totalToons + 1
    
    if toonData.Level == SI.maxLevel then
      cappedToons = cappedToons + 1
    end
  end
  indicatortip:AddLine(L["Characters"], totalToons)
  indicatortip:AddLine(string.format(L["Level %d Characters"], SI.maxLevel), cappedToons)
  if SI.db.Tooltip.TrackPlayed then
    indicatortip:AddLine((TIME_PLAYED_TOTAL):format(""),SecondsToTime(totalTime))
  end
  indicatortip:AddLine(TOTAL.." "..MONEY,SI:formatNumber(totalMoney,true))
  local realMoney = {}

  for _, info in pairs(allRealmInfo) do table.insert(realMoney, info) end
  
  table.sort(realMoney, function(a,b) return a.money > b.money end)
  for _, realmInfo in ipairs(realMoney) do
    -- Only show servers with over 10k wealth (on retail)
    -- on classic, do 100
    local showServerGoldTreshold = SI.isRetail and (10000*10000) or (10000*100)
    if realmInfo.money >= showServerGoldTreshold then 
      indicatortip:AddLine(realmInfo.realm.." "..MONEY,SI:formatNumber(realmInfo.money,true))
    end
  end

  -- history information
  indicatortip:AddLine("")
  SI:HistoryUpdate()
  local tmp = {}
  local cnt = 0
  for _,ii in pairs(SI.db.History) do
    table.insert(tmp,ii)
  end
  cnt = #tmp
  table.sort(tmp, function(i1,i2) return i1.last < i2.last end)
  indicatortip:SetCell(indicatortip:AddHeader(),1,GOLD:WrapTextInColorCode(cnt.." "..L["Recent Instances"]..": "),nil,"LEFT",2)
  for _,ii in ipairs(tmp) do
    local tstr = RED:WrapTextInColorCode(SecondsToTime(ii.last+SI.histReapTime - time(),false,false,1))
    indicatortip:AddLine(tstr, ii.desc)
  end
  indicatortip:AddLine("")
  indicatortip:SetCell(indicatortip:AddLine(), 1 ,
    string.format(
      L["These are the instances that count towards the %i instances per hour account limit, and the time until they expire."],
      SI.histLimit
    ),
    nil, "LEFT", 2, nil, nil, nil, 250
  );
  
  --- weekly rewards are only in retails
  if SI.isRetail then   
    indicatortip:AddLine("")
    indicatortip:SetCell(indicatortip:AddLine(), 1, L["|cffffff00Click|r to open weekly rewards"], nil,"LEFT", indicatortip:GetColumnCount())
  end

  indicatortip:Show()
end

hoverTooltip.ShowWorldBossTooltip = function (cell, arg, ...)
  local worldbosses = arg[1]
  local toon = arg[2]
  local saved = arg[3]
  if not worldbosses or not toon then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  local line = indicatortip:AddHeader()
  local toonstr = (SI.db.Tooltip.ShowServer and toon) or strsplit(' ', toon)
  local t = SI.db.Toons[toon]
  local reset = t.WeeklyResetTime or SI:GetNextWeeklyResetTime()
  indicatortip:SetCell(line, 1, ClassColorise(SI.db.Toons[toon].Class, toonstr), indicatortip:GetHeaderFont(), "LEFT")
  indicatortip:SetCell(line, 2, GOLD:WrapTextInColorCode(L["World Bosses"]), indicatortip:GetHeaderFont(), "RIGHT")
  indicatortip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Time Left"] .. ":"), SecondsToTime(reset - time()))
  for _, instance in ipairs(worldbosses) do
    local thisinstance = SI.db.Instances[instance]
    if thisinstance then
      local info = thisinstance[toon] and thisinstance[toon][2]
      local n = indicatortip:AddLine()
      indicatortip:SetCell(n, 1, instance, nil,"LEFT")
      if info and info[1] then
        indicatortip:SetCell(n, 2, RED:WrapTextInColorCode(ALREADY_LOOTED), nil,"RIGHT")
      else
        indicatortip:SetCell(n, 2, GREEN:WrapTextInColorCode(AVAILABLE), nil,"RIGHT")
      end
    end
  end
  indicatortip:Show()
end

hoverTooltip.ShowLFRTooltip = function (cell, arg, ...)
  local boxname, toon, tbl = unpack(arg)
  local t = SI.db.Toons[toon]
  if not boxname or not t or not tbl then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(3, "LEFT", "LEFT","RIGHT")
  local line = indicatortip:AddHeader()
  local toonstr = (SI.db.Tooltip.ShowServer and toon) or strsplit(' ', toon)
  local reset = t.WeeklyResetTime or SI:GetNextWeeklyResetTime()
  indicatortip:SetCell(line, 1, ClassColorise(SI.db.Toons[toon].Class, toonstr), indicatortip:GetHeaderFont(), "LEFT", 1)
  indicatortip:SetCell(line, 2, GOLD:WrapTextInColorCode(boxname), indicatortip:GetHeaderFont(), "RIGHT", 2)
  indicatortip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Time Left"] .. ":"), nil, SecondsToTime(reset - time()))
  for i = 1, 20 do
    local instance = tbl[i]
    local diff = 2
    if instance then
      indicatortip:SetCell(indicatortip:AddLine(), 1, LIGHTYELLOW:WrapTextInColorCode( instance ),nil, "CENTER",3)
      local thisinstance = SI.db.Instances[instance]
      local info = thisinstance[toon] and thisinstance[toon][diff]
      local killed, total, base, remap, origin = SI:GetInstanceEncounterProgress(instance,toon,diff)
      for i = base, (base + total - 1) do
        local bossid = i
        if remap then
          bossid = remap[i-base+1]
        end
        local bossname = GetLFGDungeonEncounterInfo(thisinstance.lfgDungeonID, bossid)
        local n = indicatortip:AddLine()
        indicatortip:SetCell(n, 1, bossname, nil,"LEFT", 2)
        -- for LFRs that are different between two factions
        -- https://github.com/SavedInstances/SavedInstances/pull/238
        if info and info[origin and origin[i-base+1] or bossid] then
          indicatortip:SetCell(n, 3, RED:WrapTextInColorCode(ALREADY_LOOTED),nil, "RIGHT", 1)
        else
          indicatortip:SetCell(n, 3, GREEN:WrapTextInColorCode(AVAILABLE),nil, "RIGHT", 1)
        end
      end
    end
  end
  indicatortip:Show()
end

-- Dungeon and raid encounter info tooltip
hoverTooltip.ShowIndicatorTooltip = function (cell, arg, ...)
  local instanceKey = arg[1]
  local toon = arg[2]
  local difficultyID = arg[3]
  if not instanceKey or not toon or not difficultyID then return end
  local indicatorTip = Tooltip:AcquireIndicatorTip(3, "LEFT", "LEFT","RIGHT")
  local instance = SI.db.Instances[instanceKey]
  local worldBossEncounterID = instance and instance.WorldBoss
  local lockoutInfo = instance[toon][difficultyID]
  if not lockoutInfo then return end
  local lockoutID = lockoutInfo.ID or 0
  local cellHeader = indicatorTip:AddHeader()
  indicatorTip:SetCell(cellHeader, 1, DifficultyString(instanceKey, difficultyID, toon), indicatorTip:GetHeaderFont(), "LEFT", 1)
  indicatorTip:SetCell(cellHeader, 2, GOLD:WrapTextInColorCode(instanceKey), indicatorTip:GetHeaderFont(), "RIGHT", 2)
  local toonline = indicatorTip:AddHeader()
  local toonstr = (SI.db.Tooltip.ShowServer and toon) or strsplit(' ', toon)
  indicatorTip:SetCell(toonline, 1, ClassColorise(SI.db.Toons[toon].Class, toonstr), indicatorTip:GetHeaderFont(), "LEFT", 1)
  indicatorTip:SetCell(toonline, 2, SI:GetDifficultyName(instance,difficultyID,lockoutInfo),nil, "RIGHT", 2)
  local EMPH = " !!! "
  if lockoutInfo.Extended then
    indicatorTip:SetCell(indicatorTip:AddLine(),1,WHITE:WrapTextInColorCode(EMPH .. L["Extended Lockout - Not yet saved"] .. EMPH ),nil,"CENTER",3)
  elseif lockoutInfo.Locked == false and lockoutID > 0 then
    -- cant extend in wotlk/era (will in cata tho)
    local displayStr = SI.isRetail 
      and L["Expired Lockout - Can be extended"]
      -- or RAID_INSTANCE_EXPIRED:format(instanceKey)
      or RAID_INSTANCE_EXPIRES_EXPIRED

    indicatorTip:SetCell(indicatorTip:AddLine(),1,WHITE:WrapTextInColorCode(EMPH .. displayStr .. EMPH ),nil,"CENTER",3)
  end
  if lockoutInfo.Expires > 0 then
    indicatorTip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Time Left"] .. ":"), nil, SecondsToTime(instance[toon][difficultyID].Expires - time()))
  end
  if lockoutID > 0 and (
    (instance.Raid and (difficultyID == 5 or difficultyID == 6 or difficultyID == 16)) -- raid: 10 heroic, 25 heroic or mythic
    or
    (difficultyID == 23) -- mythic 5-man
    ) then
    local n = indicatorTip:AddLine()
    indicatorTip:SetCell(n, 1, LIGHTYELLOW:WrapTextInColorCode(ID .. ":"),nil, "LEFT", 1)
    indicatorTip:SetCell(n, 2, lockoutID,nil, "RIGHT", 2)
  end
  if lockoutInfo.Link then
    ---@type string
    local link = lockoutInfo.Link
    if instance.lfgDungeonID == 1944 then
      -- Battle of Dazar'alor
      -- https://github.com/SavedInstances/SavedInstances/issues/233
      local locFaction = UnitFactionGroup("player")
      if SI.db.Toons[toon].Faction ~= locFaction then
        local bits = tonumber(link:match(":(%d+)\124h")) or 0
        if SI.db.Toons[toon].Faction == "Alliance" then
          bits = bit.band(bits, 0x3134D)
          if bit.band(bits, 0x1) > 0 then -- Grong the Revenant (Alliance)
            bits = bit.bor(bits, 0x2)
          end
          if bit.band(bits, 0x4) > 0 then -- Jadefire Masters (Alliance)
            bits = bit.bor(bits, 0x10)
          end
        else
          bits = bit.band(bits, 0x3135A)
          if bit.band(bits, 0x2) > 0 then -- Grong, the Jungle Lord (Horde)
            bits = bit.bor(bits, 0x1)
          end
          if bit.band(bits, 0x10) > 0 then -- Jadefire Masters (Horde)
            bits = bit.bor(bits, 0x4)
          end
        end
        link = "\124cffff8000\124Hinstancelock:Player-0000-00000000:2070:"
          .. difficultyID .. ":" .. bits .. "\124h[Battle of Dazar'alor]\124h\124r"
      end
    end
    SI.ScanTooltip:SetOwner(UIParent, 'ANCHOR_NONE')
   
    local isTooltipParsed = false
    -- in classic/wotlk there is no tooltip for the saved instances hyperlink (not sure if bug or intedned)
    if SI.isRetail then
      SI:Debug("Getting Encounter Info via Tooltip Scan for %s", link)
      SI.ScanTooltip:SetHyperlink(link) 
      SI.ScanTooltip:Show()
      local name = SI.ScanTooltip:GetName()
      for i=2,SI.ScanTooltip:NumLines() do
        local left,right = _G[name.."TextLeft"..i], _G[name.."TextRight"..i]
        if right and right:GetText() then
          local n = indicatorTip:AddLine()
          indicatorTip:SetCell(n, 1, coloredText(left),nil, "LEFT", 2)
          indicatorTip:SetCell(n, 3, coloredText(right),nil, "RIGHT", 1)
          isTooltipParsed = true
        else
          indicatorTip:SetCell(indicatorTip:AddLine(),1,coloredText(left),nil,"CENTER",3)
        end
      end
    end
    if not isTooltipParsed then 
      local localizedEncounters = SI:GetInstanceExceptionInfo(instance.lfgDungeonID)
      local encounterBitmap = tonumber(link:match(":(%d+)\124h"))
      if localizedEncounters and encounterBitmap then
        SI:Debug("Getting Encounter Info via hardcoded Instance Exception for %s", link)
        for i = 1, localizedEncounters.total do
          local newLine = indicatorTip:AddLine()
          indicatorTip:SetCell(newLine, 1, localizedEncounters[i], nil, "LEFT", 2)
          local text = "\124cff00ff00"..BOSS_ALIVE.."\124r"
          if bit.band(encounterBitmap,1) > 0 then
            text = "\124cffff1f1f"..BOSS_DEAD.."\124r"
          end
          indicatorTip:SetCell(newLine, 3, text,nil, "RIGHT", 1)
          encounterBitmap = bit.rshift(encounterBitmap,1)
        end
      else 
        -- no hardcoded list of encounters in the exceptions table (this should be the default for classic since no hyperlink support)
        -- SI:Debug("Getting Encounter Info via the `encounter` saved var data for db.Instances[\"%s\"][\"%s\"][%i]",instanceKey, toon, difficultyID)
        if lockoutInfo.encounters then
          for i = 1, #lockoutInfo.encounters do
            local bossName = lockoutInfo.encounters[i].localizedName
            local isComplete = lockoutInfo.encounters[i].isComplete
            local newLine = indicatorTip:AddLine()
            indicatorTip:SetCell(newLine, 1, bossName, nil, "LEFT", 2)

            local progressText = isComplete and RED:WrapTextInColorCode(BOSS_DEAD)
            or PURE_GREEN:WrapTextInColorCode(BOSS_ALIVE)

            indicatorTip:SetCell(newLine, 3, progressText, nil, "RIGHT", 1)
          end
        else
        indicatorTip:SetCell(
          indicatorTip:AddLine(), 1,
          WHITE:WrapTextInColorCode(L["Boss kill information is missing for this lockout.\nThis is a Blizzard bug affecting certain old raids."]),
          nil, "CENTER", 3
        )
        end
      end
    end
  end
  --- For LFR and world bosses
  if lockoutID < 0 then
    local killed, total, base, remap = SI:GetInstanceEncounterProgress(instanceKey,toon,difficultyID)
    for i=base,base+total-1 do
      local bossid = i
      if remap then
        bossid = remap[i-base+1]
      end
      local bossname
      if worldBossEncounterID then
        bossname = WorldBosses:GetEncounterInfo(worldBossEncounterID).name or "UNKNOWN"
      else
        bossname = GetLFGDungeonEncounterInfo(instance.lfgDungeonID, bossid)
      end
      local n = indicatorTip:AddLine()
      indicatorTip:SetCell(n, 1, bossname,nil, "LEFT", 2)
      if lockoutInfo[bossid] then
        indicatorTip:SetCell(n, 3, RED:WrapTextInColorCode(ALREADY_LOOTED),nil, "RIGHT", 1)
      else
        indicatorTip:SetCell(n, 3, GREEN:WrapTextInColorCode(AVAILABLE),nil, "RIGHT", 1)
      end
    end
  end
  indicatorTip:Show()
end

hoverTooltip.ShowSpellIDTooltip = function (cell, arg, ...)
  local toon, spellid, timestr = unpack(arg)
  if not toon or not spellid or not timestr then return end
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  indicatortip:AddHeader(ClassColorise(SI.db.Toons[toon].Class, strsplit(' ', toon)), timestr)
  if spellid > 0 then
    local tip = SI.db.spelltip and SI.db.spelltip[spellid]
    for i=1,#tip do
      indicatortip:AddLine("")
      indicatortip:SetCell(indicatortip:GetLineCount(),1,tip[i], nil, "LEFT",2, nil, nil, nil, 250)
    end
  else
    local queuestr = LFG_RANDOM_COOLDOWN_YOU:match("^(.+)\n")
    indicatortip:AddLine(LFG_TYPE_RANDOM_DUNGEON)
    indicatortip:AddLine("")
    indicatortip:SetCell(indicatortip:GetLineCount(),1,queuestr, nil, "LEFT",2, nil, nil, nil, 250)
  end
  indicatortip:Show()
end

--- show the currency info for the given toon
hoverTooltip.ShowCurrencyTooltip = function (cell, arg, ...)
  ---@type string, number, SavedInstances.Toon.Currency
  local toon, currencyID, currencyInfo = unpack(arg)
  if not (toon and currencyID and currencyInfo) then return end
  local info;
  local moduleInfo = Currency:GetCurrencyInfo(currencyID)

  -- only classic era has no Currency/Token system.
  if moduleInfo and moduleInfo.type == "item_api" then
    local description = ""
    local _, itemLink = GetItemInfo(currencyID)
    -- GameTooltip_SetBasicTooltip(SI.ScanTooltip, " ")  
    SI.ScanTooltip:SetHyperlink(itemLink)
    -- skip the first line, it's the item name.
    local numLines = SI.ScanTooltip:NumLines()
    for i = 2, numLines do
      local line = _G[SI.ScanTooltip:GetName() .. "TextLeft" .. i]
      if line then
        ---@type string?
        local text = line:GetText()
        if text then
          -- find unique count if avail and cache it in the toonDB
          if text:find(ITEM_UNIQUE) 
          and not currencyInfo.totalMax 
          then
            -- ITEM_UNIQUE_MULTIPLE = Unique (%d)
            -- need to escape the `(`, `)`, and `%` and create a capture group for 1+ digits
            -- to collect the count
            local uniqueCount = tonumber(text:match(ITEM_UNIQUE_MULTIPLE:gsub("%(%%d%)", "%%((%%d+)%%)"))) or 1
            currencyInfo.totalMax = uniqueCount
          end
          -- temporary. should ideally clone the lines in the indicator tip instead of newline seperating it and putting it all in a single line.
          description = description..(i == 1 and "" or "\n")..text
        end
      end
    end
    SI.ScanTooltip:Hide()
    info = {
      icon = GetItemIcon(currencyID),
      description = description
    }
  else
    info = C_CurrencyInfo.GetBasicCurrencyInfo(currencyID)
  end
  local tex = " \124T" .. info.icon .. ":0\124t"

  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  indicatortip:AddHeader(ClassColorise(SI.db.Toons[toon].Class, strsplit(' ', toon)), CurrencyColor(currencyInfo.amount or 0, currencyInfo.totalMax)..tex)
  indicatortip:AddLine('')
  indicatortip:SetCell(indicatortip:GetLineCount(), 1, GOLD:WrapTextInColorCode(info.description), nil, 'LEFT', 2, nil, nil, nil, 220)

  local spacer = nil
  if currencyInfo.weeklyMax and currencyInfo.weeklyMax > 0 then
    if not spacer then
      indicatortip:AddLine(" ")
      spacer = true
    end
    indicatortip:AddLine(format(CURRENCY_WEEKLY_CAP, "", CurrencyColor(currencyInfo.earnedThisWeek or 0, currencyInfo.weeklyMax), SI:formatNumber(currencyInfo.weeklyMax)))
  end
  if currencyInfo.totalEarned and currencyInfo.totalEarned > 0 and currencyInfo.totalMax and currencyInfo.totalMax > 0 then
    if not spacer then
      indicatortip:AddLine(" ")
      spacer = true
    end
    indicatortip:AddLine(format(CURRENCY_TOTAL, "", CurrencyColor(currencyInfo.amount or 0, currencyInfo.totalMax)))
    -- currently, only season currency use totalEarned
    local CURRENCY_SEASON_TOTAL_MAXIMUM = CURRENCY_SEASON_TOTAL_MAXIMUM
    if not SI.isRetail then 
      CURRENCY_SEASON_TOTAL_MAXIMUM = CURRENCY_SEASON_TOTAL:gsub("%%s$", "%%s/%%s");
    end
    indicatortip:AddLine(format(CURRENCY_SEASON_TOTAL_MAXIMUM,
      "", CurrencyColor(currencyInfo.totalEarned or 0, currencyInfo.totalMax), SI:formatNumber(currencyInfo.totalMax))
    );
  elseif currencyInfo.totalMax and currencyInfo.totalMax > 0 then
    if not spacer then
      indicatortip:AddLine(" ")
      spacer = true
    end
    indicatortip:AddLine(format(CURRENCY_TOTAL_CAP, "", CurrencyColor(currencyInfo.amount or 0, currencyInfo.totalMax), SI:formatNumber(currencyInfo.totalMax)))
  end
  if currencyInfo.covenant then
    if not spacer then
      indicatortip:AddLine(" ")
      spacer = true
    end
    for covenantID = 1, 4 do
      if currencyInfo.covenant[covenantID] then
        local data = C_Covenants.GetCovenantData(covenantID)
        local name = data and data.name or UNKNOWN
        indicatortip:AddLine(name .. ": " .. CurrencyColor(currencyInfo.covenant[covenantID] or 0, currencyInfo.totalMax))
      end
    end
  end
  if SI.specialCurrency[currencyID] and SI.specialCurrency[currencyID].relatedItem.id then
    if not spacer then
      indicatortip:AddLine(" ")
      spacer = true
    end
    local itemName = GetItemInfo(SI.specialCurrency[currencyID].relatedItem.id) or ""
    if SI.specialCurrency[currencyID].relatedItem.holdingMax then
      local holdingMax = SI.specialCurrency[currencyID].relatedItem.holdingMax
      indicatortip:AddLine(itemName .. ": " .. CurrencyColor(currencyInfo.relatedItemCount or 0, holdingMax) .. "/" .. holdingMax)
    else
      indicatortip:AddLine(itemName .. ": " .. (currencyInfo.relatedItemCount or 0))
    end
  end
  indicatortip:Show()
end

---Show currency summary in the addon tooltip
---@param cell any
---@param arg number? currencyID
---@param ... any
hoverTooltip.ShowCurrencySummary = function (cell, arg, ...)
  local currencyID = arg
  if not currencyID then return end

  -- SI:Debug("ShowCurrencySummary", currencyID)
  local name, icon;
  local info = Currency:GetCurrencyInfo(currencyID)
  if info then
    name = info.name
    icon = info.icon
  end
  icon = " \124T"..icon..":0\124t"

  ---@type boolean, string?
  local itemFlag, itemIcon = false, nil
  if SI.specialCurrency[currencyID] and SI.specialCurrency[currencyID].relatedItem.id then
    itemFlag = true
    itemIcon = select(10, GetItemInfo(SI.specialCurrency[currencyID].relatedItem.id))
    itemIcon = itemIcon and (" \124T" .. itemIcon .. ":0\124t") or ""
  end

  local indicatorTip = Tooltip:AcquireIndicatorTip(2, "LEFT","RIGHT")
  indicatorTip:AddHeader(name, "")
  local total = 0
  local totalMax ---@type number?
  local temp = {}
  for toonName, toonData in pairs(SI.db.Toons) do -- deliberately include ALL toons
    -- we should feel confident that the toonData.currency table is defined here.
    -- it should be a required field whenever a new toon is added to the db. 
    local currencyInfo = toonData.currency and toonData.currency[currencyID]
    if currencyInfo and currencyInfo.amount then
      totalMax = totalMax or currencyInfo.totalMax
      local str2 = CurrencyColor(currencyInfo.amount or 0, totalMax) .. icon
      if itemFlag then
        if SI.specialCurrency[currencyID].relatedItem.holdingMax then
          str2 = str2 .. " + " .. CurrencyColor(currencyInfo.relatedItemCount or 0, SI.specialCurrency[currencyID].relatedItem.holdingMax) .. itemIcon
        else
          str2 = str2 .. " + " .. (currencyInfo.relatedItemCount or 0) .. itemIcon
        end
      end
      tinsert(temp, {
        toon = toonName, amount = currencyInfo.amount, itemCount = currencyInfo.relatedItemCount or 0,
        str1 = ClassColorise(toonData.Class, toonName), str2 = str2,
      })
      total = total + currencyInfo.amount
    end
  end
  indicatorTip:SetCell(1,2,CurrencyColor(total,0)..icon)
  --indicatortip:AddLine(TOTAL, CurrencyColor(total,tmax)..tex)
  --indicatortip:AddLine(" ")
  SI.currency_sort = SI.currency_sort or function(a,b)
    if a.amount ~= b.amount then
      return a.amount > b.amount
    elseif a.itemCount ~= b.itemCount then
      return a.itemCount > b.itemCount
    end

    local an, as = a.toon:match('^(.*) [-] (.*)$')
    local bn, bs = b.toon:match('^(.*) [-] (.*)$')
    if SI.db.Tooltip.ServerSort and as ~= bs then
      return as < bs
    else
      return a.toon < b.toon
    end
  end
  table.sort(temp, SI.currency_sort)
  for _,t in ipairs(temp) do
    indicatorTip:AddLine(t.str1, t.str2)
  end

  indicatorTip:Show()
end

hoverTooltip.ShowKeyReportTarget = function (cell, arg, ...)
  local indicatortip = Tooltip:AcquireIndicatorTip(2, "LEFT", "RIGHT")
  indicatortip:AddHeader(
    GOLD:WrapTextInColorCode(L["Keystone report target"]),
    SI.db.Tooltip.KeystoneReportTarget
  )
  indicatortip:Show()
end

-- global addon code below

--- Initialize the store for the currently logged in character in `SI.db.Toons[SI.thisToon]`
function SI:toonInit()
  local getNewToonDefault = function()
    local localizedClass, classFile = UnitClass("player")
    local localizedRace, raceFile = UnitRace("player")
    local factionFile, localizedFaction = UnitFactionGroup("player")
    if raceFile  == "Pandaren" then
      localizedRace =  localizedRace.. " ("..localizedFaction..")"
    end
    local level = UnitLevel("player")
    local isLevelCap = level == SI.maxLevel
    local zone = GetRealZoneText() -- this function returns nil sometimes.
    return {
      Class = classFile,
      LClass = localizedClass,
      -- the convention here is a little backwards
      Race = localizedClass,
      oRace = raceFile,
      Level = UnitLevel("player"),
      Show = "saved",
      Order = 50,
      Zone = (zone and #zone > 0) and zone or nil,
      Quests = {},
      Skills = {},
      Progress = {},
      Faction = factionFile,
      DailyResetTime = SI:GetNextDailyResetTime(),
      WeeklyResetTime = SI:GetNextWeeklyResetTime(),
      currency = {},
      MaxXP = UnitXPMax("player"),
      XP = not isLevelCap and UnitXP("player") or nil,
      RestXP = not isLevelCap and GetXPExhaustion() or nil,
      isResting = IsResting(),
      Money = 0,
      LastSeen = time(),

      --- these are initialized in original code. 
      Covenant = SI.isRetail and C_Covenants.GetActiveCovenantID() or nil,
      MythicPlusScore = SI.isRetail and C_ChallengeMode.GetOverallDungeonScore() or nil,
      Warmode = SI.isRetail and C_PvP.IsWarModeDesired() or nil,
      WorldBuffs = SI.isClassicEra and {} or nil,
    } --[[@as SavedInstances.Toon]]
  end

  local toonData = SI.db.Toons[SI.thisToon] or {}
  local isNewToon = toonData.Level == nil
  local defaultData = getNewToonDefault()
  if isNewToon then
    SI.db.Toons[SI.thisToon] = defaultData
    toonData = SI.db.Toons[SI.thisToon]
  else
    for k,v in pairs(defaultData) do
      if toonData[k] == nil then
        toonData[k] = v
      end
    end
  end

  -- I feel like old keys should be removed in a more programmatic way in the DB migrations of `SI:OnInitialize`
  
  -- toonData.DailyWorldQuest = nil -- REMOVED
  -- toonData.Artifact = nil -- REMOVED
  -- toonData.Cloak = nil -- REMOVED

  -- try to get a reset time, but don't overwrite existing, which could break quest list
  -- real update comes later in UpdateToonData
  toonData.DailyResetTime = toonData.DailyResetTime or SI:GetNextDailyResetTime()
  toonData.WeeklyResetTime = toonData.WeeklyResetTime or SI:GetNextWeeklyResetTime()
end

function SI:OnInitialize()
  local versionString = C_AddOns.GetAddOnMetadata("SavedInstances", "version")
  --@debug@
  if versionString == "@project-version@" then
    versionString = "Dev"
  end
  --@end-debug@
  SI.version = versionString

  -- Get SavedVars or set to defaultDB
  ---@class SavedInstances.DB
  SavedInstancesDB = SavedInstancesDB or SI.defaultDB

  -- begin any database migrations
if not SavedInstancesDB.DBVersion or SavedInstancesDB.DBVersion < 10 then
  -- reset savedVars to defaultDB for any version < 10
  SavedInstancesDB = SI.defaultDB
  SavedInstancesDB.DBVersion = 10
end
-- Version 12 
if SavedInstancesDB.DBVersion < 12 then
  -- adds indicators
  SavedInstancesDB.Indicators = SI.defaultDB.Indicators  
  -- removed unused or deprecated `Toon` fields  
  for _, toonData in pairs(SavedInstancesDB.Toons) do
    ---@cast toonData table
    toonData.DailyWorldQuest = nil
    toonData.Artifact = nil
    toonData.Cloak = nil
  end
  SavedInstancesDB.DBVersion = 12
end
if SavedInstancesDB.DBVersion < 13 then
    -- `.currency` saved var is now initialized in `SI:toonInit()` instead of `SI:UpdateToonData()`
  for _, toonData in pairs(SavedInstancesDB.Toons) do
    toonData.currency = toonData.currency or {}
  end
end
-- end backwards compatibilty
  
  -- preserve db if function is ran while `SI.db` is still in scope
  ---@class SavedInstances.DB
  SI.db = SI.db or SavedInstancesDB
  SI:toonInit()

  -- for sake of code readability, use `SI.db` instead of `db`.
  -- its so minisculy more cost effective not having to index into `SI` everytime we want a referenced to `SI.db`, 
  -- but makes it makes the code alot harder to read/maintain.
  SI.db.History = SI.db.History or {}
  SI.db.Quests = SI.db.Quests or SI.defaultDB.Quests
  SI.db.QuestDB = SI.db.QuestDB or SI.defaultDB.QuestDB
  if SI.isRetail then
    SI.db.Emissary = SI.db.Emissary or SI.defaultDB.Emissary
    SI.db.Warfront = SI.db.Warfront or SI.defaultDB.Warfront
  end
  
  for tooltipSetting, defaultVal in pairs(SI.defaultDB.Tooltip) do
    if SI.db.Tooltip[tooltipSetting] == nil then
      SI.db.Tooltip[tooltipSetting] = defaultVal
    end
  end

  local validCurrencyLookup = {}
  for _, CurrencyID in ipairs(Currency:GetCurrencyList()) do
    validCurrencyLookup[CurrencyID] = true
    local key = "Currency".. CurrencyID
    if SI.db.Tooltip[key] == nil then
      SI.db.Tooltip[key] = SI.defaultDB.Tooltip[key]
    end
  end
  -- remove any old currencies that are no longer valid
  for _, toonData in pairs(SI.db.Toons) do
    toonData.Order = toonData.Order or 50
    if toonData.currency then
      for currencyID, currencyData in pairs(toonData.currency) do
        -- detect outdated entries because new version doesn't explicitly store max zeros
        if (currencyData.amount == 0 and (currencyData.weeklyMax == 0 or currencyData.totalMax == 0))
          or currencyData.amount == nil -- another outdated entry type created by old weekly reset logic
          or not validCurrencyLookup[currencyID] -- removed currency
        then
          toonData.currency[currencyID] = nil
        end
      end
    end
  end

  for questID, _ in pairs(SI.db.QuestDB.Daily) do
    -- Dont show quests twice if they are account wide.
    if SI.db.QuestDB.AccountDaily[questID] then
      SI:Debug("Removing character specific questDB entry for Account-wide quest at: "..questID)
      SI.db.QuestDB.Daily[questID] = nil
    end
  end

  for exceptionQuestID, exceptionQuestType in pairs(QuestExceptions) do -- upgrade QuestDB with new exceptions
    local dbValue = -1 -- default to a blank zone
    for _, questStore in pairs(SI.db.QuestDB) do
      dbValue = questStore[exceptionQuestID] or dbValue
      questStore[exceptionQuestID] = nil
    end
    if SI.db.QuestDB[exceptionQuestType] then
      SI.db.QuestDB[exceptionQuestType][exceptionQuestID] = dbValue
    end
  end

  RequestRatedInfo()
  RequestRaidInfo() -- get lockout data
  RequestLFDPlayerLockInfo()

  SI.dataobject = SI.Libs.LDB and SI.Libs.LDB:NewDataObject("SavedInstances", {
    text = "SI",
    type = "launcher",
    icon = "Interface\\Addons\\SavedInstances\\Media\\Icon.tga",
    OnEnter = function(self)
      if not Tooltip:IsDetached() and not SI.db.Tooltip.DisableMouseover then
        SI:ShowTooltip(self)
      end
    end,
    OnLeave = function(frame) end,
    OnClick = function(frame, button)
      if button == "MiddleButton" then
        if InCombatLockdown() then return end
        ToggleFriendsFrame(4) -- open Blizzard Raid window
        RaidInfoFrame:Show()
      elseif button == "LeftButton" then
        Tooltip:ToggleDetached()
      else
        Config:ShowConfig()
      end
    end
  })
  if SI.Libs.LDBI then
    SI.Libs.LDBI:Register("SavedInstances", 
      SI.dataobject --[[@as LibDBIcon.dataObject]], 
      SI.db.MinimapIcon
    )
    SI.Libs.LDBI:AddButtonToCompartment("SavedInstances")
    SI.Libs.LDBI:Refresh("SavedInstances")
  end
end

function SI:OnEnable()
  self:RegisterBucketEvent("UPDATE_INSTANCE_INFO", 2, function() SI:Refresh(nil) end)
  self:RegisterBucketEvent("LOOT_CLOSED", 1, function() SI:QuestRefresh(nil) end)
  self:RegisterBucketEvent("LFG_UPDATE_RANDOM_INFO", 1, function() SI:UpdateInstanceData(); SI:UpdateToonData() end)
  self:RegisterBucketEvent("RAID_INSTANCE_WELCOME", 1, RequestRaidInfo)
  self:RegisterEvent("CHAT_MSG_SYSTEM", function(...) SI:CheckSystemMessage(...) end)
  self:RegisterEvent("CHAT_MSG_CURRENCY", function(...) SI:CheckSystemMessage(...) end)
  self:RegisterEvent("CHAT_MSG_LOOT", function(...) SI:CheckSystemMessage(...) end)
  self:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN", function() SI:UpdateToonData() end)
  self:RegisterEvent("PLAYER_UPDATE_RESTING", function() SI:UpdateToonData() end)
  self:RegisterEvent("PVP_RATED_STATS_UPDATE", function() SI:UpdateToonData() end)
  -- self:RegisterEvent("COVENANT_CHOSEN", function() SI:UpdateToonData() end)
  -- self:RegisterEvent("MYTHIC_PLUS_NEW_WEEKLY_RECORD", function() SI:UpdateToonData() end)
  self:RegisterEvent("ZONE_CHANGED_NEW_AREA", RequestRatedInfo)
  self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    C_Timer.After(1, function()
      RequestRatedInfo()
      RequestRaidInfo()
    end)

    SI:UpdateToonData()
  end)
  -- Update rating on spec change because Solo Shuffle is unique to each spec
  self:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED", function()
    C_Timer.After(1, function()
      RequestRatedInfo()
      RequestRaidInfo()
    end)

    SI:UpdateToonData()
  end)
  -- self:RegisterBucketEvent("PLAYER_ENTERING_WORLD", 1, RequestRaidInfo)
  self:RegisterBucketEvent("LFG_LOCK_INFO_RECEIVED", 1, RequestRaidInfo)
  self:RegisterEvent("PLAYER_LOGOUT", function() SI.logout = true ; SI:UpdateToonData() end) -- update currency spent
  self:RegisterEvent("LFG_COMPLETION_REWARD", "RefreshLockInfo") -- for random daily dungeon tracking
  self:RegisterEvent("TIME_PLAYED_MSG", function(_,total,level)
    local t = SI.thisToon and SI and SI.db and SI.db.Toons[SI.thisToon]
    if total > 0 and t then
      t.PlayedTotal = total
      t.PlayedLevel = level
    end
    SI.PlayedTime = time()
    if SI.playedpending then
      for c,_ in pairs(SI.playedreg) do
        c:RegisterEvent("TIME_PLAYED_MSG") -- Restore default
      end
      SI.playedpending = false
    end
  end)

  if not SI.resetDetect then
    SI.resetDetect = CreateFrame("Button", "SavedInstancesResetDetectHiddenFrame", UIParent)
    for _,e in pairs({
      "RAID_INSTANCE_WELCOME",
      "PLAYER_ENTERING_WORLD", "CHAT_MSG_SYSTEM", "CHAT_MSG_ADDON",
      "ZONE_CHANGED_NEW_AREA",
      "INSTANCE_BOOT_START", "INSTANCE_BOOT_STOP", "GROUP_ROSTER_UPDATE",
    }) do
      SI.resetDetect:RegisterEvent(e)
    end
  end
  SI.resetDetect:SetScript("OnEvent", SI.HistoryEvent)
  C_ChatInfo.RegisterAddonMessagePrefix("SavedInstances")
  SI:HistoryEvent("PLAYER_ENTERING_WORLD") -- update after initial load
  SI:ValidateAndGetSpecialQuests()
  SI:updateRealmMap()
end

function SI:OnDisable()
  self:UnregisterAllEvents()
  SI.resetDetect:SetScript("OnEvent", nil)
end

-- request lock info from the server immediately
function SI:RequestLockInfo() 
  RequestRaidInfo()
  RequestLFDPlayerLockInfo()
end

-- throttled lock update with retry
function SI:RefreshLockInfo() 
  local now = GetTime()
  if now > (SI.lastrefreshlock or 0) + 1 then
    SI.lastrefreshlock = now
    SI:RequestLockInfo()
  end
  if now > (SI.lastrefreshlocksched or 0) + 120 then
    -- make sure we update any lockout info (sometimes there's server-side delay)
    SI.lastrefreshlockshed = now
    SI:ScheduleTimer("RequestLockInfo",5)
    SI:ScheduleTimer("RequestLockInfo",30)
    SI:ScheduleTimer("RequestLockInfo",60)
    SI:ScheduleTimer("RequestLockInfo",90)
    SI:ScheduleTimer("RequestLockInfo",120)
  end
end

local currencyPattern = CURRENCY_GAINED:gsub(":.*$","")
function SI:CheckSystemMessage(_, msg)
  local isInInstance, instancyType = IsInInstance()
  -- note: currency is already updated in TooltipShow,
  -- here we just hook JP/VP currency messages to capture lockout changes
  if isInInstance 
  -- dont update on bg honor
    and (instancyType == "party" or instancyType == "raid") 
    and (msg:find(INSTANCE_SAVED) -- first boss kill
    or msg:find(currencyPattern)) -- subsequent boss kills (unless capped or over level)
  then
    SI:RefreshLockInfo()
  end
end
--- Update the connected realms table.
---@see SavedInstances.DB.RealmMap
function SI:updateRealmMap()
  -- normalize realm name by removing whitespace
  -- local realm = GetRealmName():gsub("%s+","")
  local normalizedRealm = GetNormalizedRealmName();
  
  ---@type string[] already normalized by blizz
  local connectedRealms = GetAutoCompleteRealms() or {};

  local realmMap = SI.db.RealmMap or {}
  SI.db.RealmMap = realmMap

  -- connected-realms detected
  if #connectedRealms > 0 then
    table.sort(connectedRealms)
    -- find existing map
    local realmGroupID = realmMap[normalizedRealm]
    if not realmGroupID then
      for _, connectedRealm in ipairs(connectedRealms) do
        realmGroupID = realmGroupID or realmMap[connectedRealm]
      end
    end
    if realmGroupID then -- check for possible expansion
      local oldConnectedRealms = realmMap[realmGroupID] or {}
      if #connectedRealms > #oldConnectedRealms then
        realmMap[realmGroupID] = connectedRealms
      end
    else -- new map
      realmGroupID = #realmMap + 1
      realmMap[realmGroupID] = connectedRealms
    end

    -- maintain inverse mapping
    for _, realm in ipairs(realmMap[realmGroupID]) do 
      realmMap[realm] = realmGroupID
    end
  end
end

--- Returns realm-group-id, { realm1, realm2, ...} for connected realm, or nil,nil for unconnected
---@param realmName string realm name (normalized or not)
---@return number? groupID realm group index (key into `SI.db.RealmMap`)
---@return string[]? connectedRealms array of normalized connected realm names.
function SI:getRealmGroup(realmName)
  -- returns realm-group-id, { realm1, realm2, ...} for connected realm, or nil, nil for unconnected
  realmName = realmName:gsub("%s+","")
  local realmMap = SI.db.RealmMap
  local connectedIdx = realmMap and realmMap[realmName]
  return connectedIdx, connectedIdx and realmMap[connectedIdx]
end

--- Get the group type for the currently logged in character.
--- returns `nil` if not in a group.
---@return "RAID"|"PARTY"? groupType
function SI:InGroup()
  if IsInRaid() then return "RAID"
  elseif GetNumGroupMembers() > 0 then return "PARTY"
  else return nil end
end

--- Called whenever an *actual* instance reset it preformed.
--- calls `SI:HistoryUpdate` and  sends a "GENERATION_ADVANCE" addon message to the group on successful resets.
--- Sends a chat message if the options is set.
local function doExplicitReset(instanceMsg, resetFailed)
  if HasLFGRestrictions() or IsInInstance() or
    (SI:InGroup() and not UnitIsGroupLeader("player")) then return end
  if not resetFailed then
    SI:HistoryUpdate(true)
  end

  local reportChannel = SI:InGroup()
  local addonPrefix = "SavedInstances"
  if reportChannel then
    if not resetFailed then
      C_ChatInfo.SendAddonMessage(addonPrefix, "GENERATION_ADVANCE", reportChannel)
    end
    if (SI.isRetail 
      -- on wrath/era defer announcement to NIT
      or not C_AddOns.IsAddOnLoaded("NovaInstanceTracker")
      ---@diagnostic disable-next-line: undefined-global
      or not NIT.db.sv.global.instanceResetMsg
    ) 
     and SI.db.Tooltip.ReportResets 
    then
      local msg = instanceMsg or RESET_INSTANCES
      msg = msg:gsub("\1241.+;.+;","") -- ticket 76, remove |1;; escapes on koKR
      SendChatMessage("<"..addonPrefix.."> "..msg, reportChannel)
    end
  end
end
hooksecurefunc("ResetInstances", doExplicitReset)

local resetSuccessPattern = INSTANCE_RESET_SUCCESS:gsub("%%s",".+")
local resetFailPatterns = { 
  INSTANCE_RESET_FAILED, 
  INSTANCE_RESET_FAILED_OFFLINE, 
  INSTANCE_RESET_FAILED_ZONING 
}
for idx, pattern in pairs(resetFailPatterns) do
  resetFailPatterns[idx] = pattern:gsub("%%s",".+")
end
local raidDifficultyPattern = ERR_RAID_DIFFICULTY_CHANGED_S:gsub("%%s",".+")
local dungDifficultyPattern = ERR_DUNGEON_DIFFICULTY_CHANGED_S:gsub("%%s",".+")
local delaytime = 3 -- seconds to wait on zone change for settings to stabilize

---@alias HistoryEvent 
---| "'CHAT_MSG_ADDON'" # for "GENERATION_ADVANCE" addon message.
---| "'CHAT_MSG_SYSTEM'" # for matching instance reset related chat messages.
---| "'INSTANCE_BOOT_START'" # countdown to boot a player from an instance starts. 
---| "'INSTANCE_BOOT_STOP'" # countdown to boot a player from an instance stops.
---| "'GROUP_ROSTER_UPDATE'" # to track when player acutally leaves the group.
---| "'PLAYER_ENTERING_WORLD'" # 
---| "'ZONE_CHANGED_NEW_AREA'" # 
---| "'RAID_INSTANCE_WELCOME'" # https://warcraft.wiki.gg/wiki/RAID_INSTANCE_WELCOME

--- Handles and parses instance reset related events.
--- Determines if an instance reset has actually occured and calls `SI:HistoryUpdate` accordingly
---@param f unknown
---@param event HistoryEvent
---@param ... any event args
function SI.HistoryEvent(f, event, ...)
  -- SI:Debug("HistoryEvent: "..evt, ...)
  if event == "CHAT_MSG_ADDON" then
    local prefix, message, channel, sender = ...
    if prefix ~= "SavedInstances" then return end
    ---@cast sender string
    -- why use exact string pattern matching instead of equality checking?
    -- if message:match("^GENERATION_ADVANCE$") and not UnitIsUnit(sender,"player") then
    if message == "GENERATION_ADVANCE" 
      -- i think sender is a player name not a unitID
      -- this check would always resolve to true.
      and not UnitIsUnit(sender,"player") 
      -- matches on player "first name" only. could add server match as well
      and strsplit("-", sender) == UnitName("player")
    then
      SI:HistoryUpdate(true)
    end
  elseif event == "CHAT_MSG_SYSTEM" then
    local message = ... ---@type string
    if message:match("^"..resetSuccessPattern.."$") then -- I performed expicit reset
      doExplicitReset(message)
    elseif message:match("^"..INSTANCE_SAVED.."$") then -- just got saved
      SI:ScheduleTimer("HistoryUpdate", delaytime + 1)
    elseif (message:match("^"..raidDifficultyPattern.."$") 
      or message:match("^"..dungDifficultyPattern.."$")) 
      and not SI:histZoneKey() -- ignore difficulty messages when creating a party while inside an instance
    then 
      SI:HistoryUpdate(true)
    elseif message:match(TRANSFER_ABORT_TOO_MANY_INSTANCES) then
      SI:HistoryUpdate(false,true)
    else
      for _, failPattern in pairs(resetFailPatterns) do
        if message:match("^"..failPattern.."$") then
          doExplicitReset(message, true) -- send failure chat message
        end
      end
    end
  elseif event == "INSTANCE_BOOT_START" then -- left group inside instance, resets on boot
    SI:HistoryUpdate(true)
  elseif event == "INSTANCE_BOOT_STOP" and SI:InGroup() then -- invited back
    SI.delayedReset = false
  elseif event == "GROUP_ROSTER_UPDATE" 
    and SI.histInGroup and not SI:InGroup() -- ignore failed invites when solo
    and not SI:histZoneKey() -- left group outside instance, resets now
  then 
    SI:HistoryUpdate(true)
  elseif event == "PLAYER_ENTERING_WORLD" 
    or event == "ZONE_CHANGED_NEW_AREA" 
    or event == "RAID_INSTANCE_WELCOME" 
  then
    -- delay updates while settings stabilize
    local waittime = delaytime + math.max(0,10 - GetFramerate())
    SI.delayUpdate = time() + waittime
    SI:ScheduleTimer("HistoryUpdate", waittime+1)
  end
end

-- Time it takes for instance limit to reset.
SI.histReapTime = 60*60 -- 1 hour in seconds. 

-- Instances limit per "histReapTime". 
-- Different for different versions of the game. 
-- retail: 10
-- classic & wotlk: 5
SI.histLimit = SI.isRetail and 10 or 5
-- additionaly classic and wrath have a 30 instances per day limit.

--- Detect if players current zone is an instance with lockout info.
-- Return the instance's histKey, description string, and wether or not the player is locked to the instance. 
---@return string? histKey string used to index `SI.db.History`. formatted `<toonName>:<instanceName>:<instanceType>:<difficultyID>[:<histGeneration>]`
---@return string? descString string describing instance. formatted `<toonName>: <instanceName>[ - <difficultyName>]`. Text in brackets IFF instance has a difficulty name.
---@return boolean? zoneIsLocked
function SI:histZoneKey()
  local currentToonName = SI.thisToon
  local instanceName, instanceType, difficultyID, difficultyName, 
    maxPlayers, playerDifficulty, isDynamicInstance = GetInstanceInfo()

  -- pvp instances dont count
  if instanceType == nil 
    or instanceType == "none" 
    or instanceType == "arena" 
    or instanceType == "pvp" 
  then return nil end
  
  -- LFG instances don't count, 
  if (IsInLFGDungeon() or IsInScenarioGroup()) 
  and difficultyID ~= 19 and difficultyID ~= 17  -- but Holiday Events and LFR both count
  then return nil end

  -- Garrisons don't count (not in wotlk)
  if C_Garrison and C_Garrison.IsOnGarrisonMap() 
  then return nil end

  -- check if we're locked (using FindInstance so we don't complain about unsaved unknown instances)
  local instanceKey = SI:FindInstance(instanceName, instanceType == "raid")
  local playerIsLocked = false

  local currentInstance = instanceKey and SI.db.Instances[instanceKey] or {}
  local instanceLockouts = currentInstance[currentToonName] or {}
  
  --- check if current toon locked to *any* difficulty.
  -- (not sure what the purpose of this code is)
  for _difficultyID = 1, MAX_DIFFICULTY_ID do
    if instanceLockouts[_difficultyID] 
      and instanceLockouts[_difficultyID].Locked 
    then
      playerIsLocked = true
    end
  end
  
  -- never locked to 5-man regs
  if difficultyID == 1 and maxPlayers == 5 then 
    playerIsLocked = false
  end

  if not SI.db.Tooltip.ShowServer then
    currentToonName = strsplit(" - ", currentToonName)
  end

  local descString = currentToonName .. ": " .. instanceName
  if #difficultyName > 0 then
    descString = descString .. " - " .. difficultyName
  end

  local histKey = SI.thisToon..":"..instanceName..":"..instanceType..":"..difficultyID
  if not playerIsLocked then
    histKey = histKey..":"..SI.db.histGeneration
  end
  return histKey, descString, playerIsLocked
end

--- Updates instance history for tracking hourly instance limit (`SI.histLiveCount`).
--- Inserts, cleans, and counts entries in the `SI.db.History` table.
---@param forceReset boolean? force a reset of the instance history
---@param forceMsg boolean? force a chat message to be sent
function SI:HistoryUpdate(forceReset, forceMsg)
  -- Default value *should* be set on default db construction for each character
  -- but it sometimes is nil. bug?
  SI.db.histGeneration = SI.db.histGeneration or 1
  
  local now = time()
  local histKey, zoneDescr, isPlayerLocked = SI:histZoneKey()
  local isValidInstance = histKey ~= nil
  local isPlayerZoningIn = false

  if forceReset and isValidInstance then -- delay reset until we zone out
    SI:Debug("HistoryUpdate: Reset update delayed until the instance is left.")
    SI.delayedReset = true
  end
  
  if (forceReset or SI.delayedReset) and not isValidInstance then
    SI.db.histGeneration = (SI.db.histGeneration + 1) % 100000
    SI:Debug("HistoryUpdate: Generation increased to %i", SI.db.histGeneration)
    SI.delayedReset = false
  end

  if SI.delayUpdate and now < SI.delayUpdate then
    SI:Debug("HistoryUpdate: Delayed until 'settings stabalize'.")
    return
  end
  
  -- touch zone we left
  if SI.histLastZone then
    local lastInstanceHist = SI.db.History[SI.histLastZone --[[@as string]]]
    if lastInstanceHist then
      lastInstanceHist.last = now
    end
  elseif histKey then
    isPlayerZoningIn = true
  end

  SI.histLastZone = histKey
  SI.histInGroup = SI:InGroup()
  
  -- touch/create new zone history
  if histKey and zoneDescr then
    local instanceHistory = SI.db.History[histKey] 
    if not instanceHistory then
      instanceHistory = { 
        create = now,
        desc = zoneDescr 
      }
      if isPlayerLocked then -- creating a locked instance, delete unlocked version
        SI.db.History[histKey..":"..SI.db.histGeneration] = nil
      end
      -- add table to index
      SI.db.History[histKey] = instanceHistory
    end
    instanceHistory.last = now
  end

  -- reap old zones
  local liveCount = 0
  local oldestKey, oldestTime
  for historyKey, history in pairs(SI.db.History) do
    if now > history.last + SI.histReapTime 
      or history.last > (now + 3600) -- temporary bug fix 
    then 
      SI:Debug("HistoryUpdate: %s instance lockout expired. ", history.desc)
      SI.db.History[historyKey] = nil
    else
      liveCount = liveCount + 1
      if not oldestTime or history.last < oldestTime then
        oldestKey = historyKey
        oldestTime = history.last
      end
    end
  end
  local nextExpire = oldestTime and (oldestTime +SI.histReapTime - now)
  local expirationTimeStr = (nextExpire and SecondsToTime(nextExpire, false, false, 1)) or "n/a"
  -- local oldestremtm = (nextExpire and SecondsToTime(math.floor((nextExpire+59)/60)*60,false,false,1)) or "n/a"
  if SI.db.dbg then
    local debugStr  = "%i live instances, oldest (%s) expires in %s. Current Zone=%s"
    msg = debugStr:format(liveCount, oldestKey or "none", expirationTimeStr, histKey or "nil")
    
    if msg ~= SI.lasthistdbg then
      SI.lasthistdbg = msg
      SI:Debug(msg)
    end
    -- SI:Debug(SI.db.History)
  end

  -- print update notification (if forced or `LimitWarn`, option set)
  if forceMsg 
    or (SI.db.Tooltip.LimitWarn and isPlayerZoningIn and liveCount >= SI.histLimit-1) 
  then
    SI:ChatMsg(L["Warning: You've entered about %i instances recently and are approaching the %i instance per hour limit for your account. More instances should be available in %s."],liveCount, SI.histLimit, expirationTimeStr)
  end

  SI.histLiveCount = liveCount
  SI.histOldest = expirationTimeStr

  if SI.db.Tooltip.HistoryText and liveCount > 0 then
    SI.dataobject.text = "("..liveCount.."/"..(expirationTimeStr or "?")..")"
    SI.histTextthrottle = math.min(nextExpire + 1, SI.histTextthrottle or 15)
    SI.resetDetect:SetScript("OnUpdate", SI.histTextUpdate)
  else
    SI.dataobject.text = "SI"
    SI.resetDetect:SetScript("OnUpdate", nil)
  end
end

--- function used to manage throttling of the tooltip text updating.
---@param self SavedInstances
---@param elap number time elapsed since last update
function SI.histTextUpdate(self, elap)
  SI.histTextthrottle = SI.histTextthrottle - elap
  if SI.histTextthrottle > 0 then return end
  SI.histTextthrottle = 15
  SI:HistoryUpdate()
end

--- Save on memory churn by reusing arrays in updates
local function localarr(name) 
  name = "localarr#"..name
  SI[name] = SI[name] or {}
  return wipe(SI[name])
end

function SI:memcheck(context)
  UpdateAddOnMemoryUsage()
  local newval = GetAddOnMemoryUsage("SavedInstances")
  SI.memusage = SI.memusage or 0
  if newval ~= SI.memusage then
    SI:Debug("%.3f KB in %s",(newval - SI.memusage),context)
    SI.memusage = newval
  end
end

--- Lightweight refresh of just quest flag information,
-- all may be nil if not instantiataed.
---@param recoverDailies boolean? if `SI:QuestRefresh` should run the dailies recovery logic
---@param nextDailyReset number? time of next daily reset.
---@param nextWeeklyReset number? time of next weekly reset.
function SI:QuestRefresh(recoverDailies, nextDailyReset, nextWeeklyReset)
  local savedPlayerQuests = SI.db.Toons[SI.thisToon] and SI.db.Toons[SI.thisToon].Quests
  if not savedPlayerQuests then return end
  nextDailyReset = nextDailyReset or SI:GetNextDailyResetTime() -- why not do this with the parameter when the function is called?
  nextWeeklyReset = nextWeeklyReset or SI:GetNextWeeklyResetTime() -- same here
  
  if not nextDailyReset or not nextWeeklyReset then return end

  for _, specialQuest in pairs(SI:ValidateAndGetSpecialQuests()) do
    local questID = specialQuest.quest
    if C_QuestLog.IsQuestFlaggedCompleted(questID) then
      savedPlayerQuests[questID] = {
          Title = specialQuest.name,
          Zone = specialQuest.zone,
          isDaily = specialQuest.daily or nil,
          Expires = specialQuest.daily and nextDailyReset or nextWeeklyReset,
      }
    end
  end

  local now = time()
  SI.db.QuestDB.Weekly.expires = nextWeeklyReset
  SI.db.QuestDB.AccountWeekly.expires = nextWeeklyReset
  SI.db.QuestDB.Darkmoon.expires = SI:GetNextDarkmoonFaireEnd()

  for questType, allTrackedQuests in pairs(SI.db.QuestDB) do
    local playerOrAccountQuests = savedPlayerQuests

    if questType == "AccountDaily" or questType == "AccountWeekly" then
      playerOrAccountQuests = SI.db.Quests -- Account Quesets
    end
    if recoverDailies or (questType ~= "Daily") then
      for questID, mapID in pairs(allTrackedQuests) do
        if type(questID) == "number" then -- mind the "expires" key in the table
          -- hackish: clear stale dmf entries when dmf is active (shouldn't happen anymore)
          if questType == "Darkmoon" and SI:IsDarkmoonFaireActive() and playerOrAccountQuests[questID]
            and not C_QuestLog.IsQuestFlaggedCompleted(questID)
          then
            playerOrAccountQuests[questID] = nil
          end

          if C_QuestLog.IsQuestFlaggedCompleted(questID)
              and not playerOrAccountQuests[questID] -- recovering a lost quest
              and (allTrackedQuests.expires == nil or allTrackedQuests.expires > now)
          then
            local title, link = SI:QuestInfo(questID)
            if title then
              local found
              -- both player and account quest stores are indexed by quest id
              -- so why not just use the questID instead of iterating the whole table for a name match?
              for _, quest in pairs(playerOrAccountQuests) do
                -- avoid faction duplicates, since both flags are set
                if title == quest.Title then
                  found = true
                  break
                end
              end
              if not found
              and (questType ~= "Darkmoon" or SI:IsDarkmoonFaireActive()) -- only repop darkmoon quests if faire is active
              then
                SI:Debug("Restoring completed tracked quest: %s [%i] | type: \"%s\" |n character: %s | expires: %s",
                  link or title, questID, questType, SI.thisToon, date("%c", allTrackedQuests.expires)
                )
                playerOrAccountQuests[questID] = {
                  Title = title,
                  Link = link,
                  isDaily = questType:find("Daily") and true or false,
                  Expires = allTrackedQuests.expires,
                  Zone = C_Map.GetMapInfo(mapID)
                }
              end
            end
          end
        end
      end
    end
  end
  -- why is this called?
  SI:QuestCount(SI.thisToon)
end

--- Performs a variety of tasks in relation to refreshing the addon's database state.
--- Including but not limited to: `SI.db.Instances`, `SI.db.Toons`, `SI.db.Quests`, `SI.db.History`.
---@param recoverDailies boolean? if `SI:QuestRefresh` should run the dailies recovery logic
function SI:Refresh(recoverDailies)
  -- update entire database from the current character's perspective
  SI:UpdateInstanceData()

  -- flags here are used to avoid infinite recursion between `SI:Refresh` and `SI:UpdateInstanceData`
  -- this system should be reworked.
  if not SI.instancesUpdated then
    SI.RefreshPending = true
    return
  end -- wait for UpdateInstanceData to succeed

  local nextDailyReset = SI:GetNextDailyResetTime()
  if not nextDailyReset 
  -- allow 5 minutes for quest DB to update after daily rollover
    or ((nextDailyReset - time()) > (24*3600 - 5*60)) 
  then  
    SI:Debug("Skipping SI:Refresh() near daily reset")
    SI:UpdateToonData()
    return
  end

  local temp = localarr("RefreshTemp")
  
  -- clear current toons lockouts before refresh
  for key, lockouts in pairs(SI.db.Instances) do 
    local dungeonID = lockouts.lfgDungeonID
    if lockouts[SI.thisToon]
    -- disabled for ticket 178/195:
    --and not (id and SI.LFRInstances[id] and select(2,GetLFGDungeonNumEncounters(id)) == 0) -- ticket 103
    then
      temp[key] = lockouts[SI.thisToon] -- use a temp to reduce memory churn
      for diffID, lockoutInfo in pairs(temp[key]) do
        wipe(lockoutInfo)
      end
      lockouts[SI.thisToon] = nil
    end
  end

--- Re-populate lockout info using `GetSavedInstanceInfo`, this info is stored in saved vars. 
  local numSaved = GetNumSavedInstances()
  SI:Debug("Refreshing %i instance(s) for %s", numSaved, SI.thisToon)
  if numSaved > 0 then
    for i = 1, numSaved do
      local name, lockoutID, lockoutDuration, diffID, isLocked,
        isExtended, _, isRaid, maxPlayers, 
        diffName, numEncounters, numCompleted = GetSavedInstanceInfo(i)
      local _, dungeonID = SI:FindInstance(name, isRaid)
      if not dungeonID then
        SI:Debug("Saved to unknown Instance: %s. Not recording it. Please report this issue.", name);
        return;
      end      
      local instanceKey, instanceEntry = SI:LookupInstance(nil, name, isRaid)
      if instanceKey and instanceEntry then
        ---@type {localizedName: string, isCompleted: boolean?}[]
        local encounters = {}
        for j = 1, numEncounters do
          local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, j)
          encounters[j] = { localizedName = bossName, isComplete = isKilled }
        end
        
        local lockoutExpiry = lockoutDuration and (lockoutDuration + time()) or 0
        -- SI:Debug("instanceKey %s | reset time %d ", instanceKey or "nil", lockoutExpiry or 69);
        
        
        -- If an unreferenced empty table is returned from `LookupInstance`
        if not instanceEntry.lfgDungeonID 
          or not SI.db.Instances[instanceKey]
          then 
            ---@cast instanceEntry SavedInstances.DB.Instance.Entry
            -- add ref in the db so table can be modified.
            SI.db.Instances[instanceKey] = instanceEntry
            instanceEntry.lfgDungeonID = instanceEntry.lfgDungeonID
            instanceEntry.Raid = isRaid
          end
          --- add this character into the instance entry's toon table
          instanceEntry[SI.thisToon] = instanceEntry[SI.thisToon] or {}
          ---@type SavedInstances.DB.Instance.LockoutInfo
          instanceEntry[SI.thisToon][diffID] = {
            ID = lockoutID,
          Expires = lockoutExpiry,
          Link = GetSavedInstanceChatLink(i),
          Locked = isLocked,
          Extended = isExtended,
          encounters = encounters,
          numEncounters = numEncounters,
          numCompleted = numCompleted
        }

        -- update the instances db with info from this lockout.
        -- ViragDevTool:AddData(instanceEntry, "entry")
        assert(instanceEntry.encountersByDifficulty, "encountersByDifficulty is nil")
        instanceEntry.encountersByDifficulty[diffID] = instanceEntry.encountersByDifficulty[diffID] or {}
        instanceEntry.encountersByDifficulty[diffID] = encounters
      end
    end
  end

  -- upsert LFR lockout info using `GetLFGDungeonEncounterInfo`
  local nextWeeklyReset = SI:GetNextWeeklyResetTime()
  for lfrDungeonID,_ in pairs(SI.LFRInstances) do
    local numEncounters, numCompleted = GetLFGDungeonNumEncounters(lfrDungeonID)
    if ( numCompleted and numCompleted > 0 and nextWeeklyReset ) then
      local lfrInstanceKey, instanceEntry = SI:LookupInstance(lfrDungeonID, nil, true)
      if lfrInstanceKey and instanceEntry then
        instanceEntry[SI.thisToon] = instanceEntry[SI.thisToon] or temp[lfrInstanceKey] or { }
        -- why use difficultyID of 2 when LFR has its own ID of 17? https://warcraft.wiki.gg/wiki/DifficultyID
        local info = instanceEntry[SI.thisToon][2] or {}
        instanceEntry[SI.thisToon][2] = info
        
        -- ticket 109: don't refresh expiration close to reset, hardcoded 5 minutes.
        if not (info.Expires and info.Expires < (time() + 300)) then
          wipe(info)
          info.Expires = nextWeeklyReset
        end

        info.ID = -1*numEncounters
        
        for i=1, numEncounters do
          local bossName, icon, isKilled = GetLFGDungeonEncounterInfo(lfrDungeonID, i)
          info[i] = isKilled
        end
      end
    end
  end
  if WorldBosses then
    local wbsave = localarr("wbsave")
    if GetNumSavedWorldBosses and GetSavedWorldBossInfo then -- 5.4
      for i = 1, GetNumSavedWorldBosses() do
        local name, id, reset = GetSavedWorldBossInfo(i)
        wbsave[name] = true
      end
    end
    for _, encounterInfo in WorldBosses:IterateBossEncounterInfo() do
      if nextWeeklyReset and ((encounterInfo.quest and C_QuestLog.IsQuestFlaggedCompleted(encounterInfo.quest))
            or wbsave[encounterInfo.name])
      then
        local instanceKey = encounterInfo.name
        local instance = SI.db.Instances[instanceKey]
        instance[SI.thisToon] = instance[SI.thisToon] or temp[instanceKey] or {}
        -- use a difficulty id of 2 for wolrd bosses.
        local info = instance[SI.thisToon][2] or {}
        wipe(info)
        instance[SI.thisToon][2] = info
        info.Expires = nextWeeklyReset
        info.ID = -1
        info[1] = true
      end
    end
  end

  SI:QuestRefresh(recoverDailies, nextDailyReset, nextWeeklyReset)
  
  ---@diagnostic disable-next-line: undefined-field
  if SI.isRetail and Warfront then Warfront:UpdateQuest() end -- not in wotlk

  -- not sure what the purpose of the follow code is
  local numInstances, numDifficulties = 0,0
  for instanceKey, _ in pairs(temp) do
    if SI.db.Instances[instanceKey][SI.thisToon] then
      for diffID, lockout in pairs(SI.db.Instances[instanceKey][SI.thisToon]) do
        if not lockout.ID then
          SI.db.Instances[instanceKey][SI.thisToon][diffID] = nil
          numDifficulties = numDifficulties + 1
        end
      end
    else
      numInstances = numInstances + 1
    end
  end
  SI:Debug("Refresh Finisheed: "
    ..numInstances.." instances, and "
    ..numDifficulties.." difficulties validated."
  )
  wipe(temp)
  SI:UpdateToonData()
end

local function UpdateTooltip(self, elapsed)
  if not self.anchorframe then
    self:SetScript('OnUpdate', nil)
    return
  end

  self.elapsed = (self.elapsed or 10) + elapsed
  if self.elapsed < 0.5 then return end
  self.elapsed = 0

  SI:ShowTooltip(self.anchorframe)
end

-- sorted traversal function for character table
local cpairs
do
  ---@type table<number, table<number, string|number>>
  local sortEntries = {}
  local nextIndex
  local sortedPosition
  
  
  -- get the character index and data for the next character
  local function cnext(characters, idx)
    local realmGroup = sortEntries[nextIndex]
    if not realmGroup then return nil end -- end of table reached
    
    nextIndex = nextIndex + 1
    --- last sortedPosition should be the name for highest sorted current character
    local toonIndex = realmGroup[sortedPosition]
    return toonIndex, characters[toonIndex]
  end

  -- returns `true` if at least value in `t1` is less than the corresponding value in `t2`
  local function cpairs_sort(t1, t2) 
    -- generic multi-key sort
    for idx, val1 in ipairs(t1) do
      local val2 = t2[idx]
      if val1 ~= val2 then
        return val1 < val2
      end
    end
    return false -- required for sort stability when a==a
  end

  ---@generic T: table, V
  ---@param characters T<string, V>
  ---@param useCache boolean? # if `true` the function will use the cached `sortEntries` table. 
  ---@return fun(chars: T, idx: number?): string, V
  ---@return T
  ---@return nil
  cpairs = function(characters, useCache)
    local tooltipOptions = SI.db.Tooltip
    local currGroupPosition ---@type number?

    -- Maps a realm group id to the lowest sorted realm (alphabetical) for that group.
    ---@type table<number, string>
    local minRealmForGroup = {}

    if not useCache then
      local realmName = GetRealmName()
      local realmGroupIdx; ---@type integer?
      
      if tooltipOptions.ConnectedRealms ~= "ignore" then
        realmGroupIdx = SI:getRealmGroup(realmName)
      end

      wipe(sortEntries)
      nextIndex = 1
      for characterKey, _ in pairs(characters) do 
        local characterStore = SI.db.Toons[characterKey]
        ---@type any, string
        local _, toonRealm = characterKey:match('^(.*) [-] (.*)$')
        
        if characterStore 
        and (characterStore.Show ~= "never" 
          or (characterKey == SI.thisToon and tooltipOptions.SelfAlways))
        and (not tooltipOptions.ServerOnly
          or realmName == toonRealm
          or (
            realmGroupIdx -- 2 diff servers without realmgroups both use `nil`
            and realmGroupIdx == SI:getRealmGroup(toonRealm))
          )
        then
          -- Maps a sorted index to either the realm group index for `SI.db.RealmMap`, or a specific realm name
          ---@type {[number]: string|number}
          local sortedRealmOrGroup = {}
          local sortedCharacters
          sortedPosition = 1

          if tooltipOptions.SelfFirst then
            if characterKey == SI.thisToon then
              -- make the whole realm group 1 the (next) highest sorted position
              sortedRealmOrGroup[sortedPosition] = 1
            else
              -- followed by realm group two
              sortedRealmOrGroup[sortedPosition] = 2
            end
            sortedPosition = sortedPosition + 1
          end
          --- is this sortByServer or sortCharsInServer?
          if tooltipOptions.ServerSort then
            if tooltipOptions.ConnectedRealms == "ignore" then
              -- only add current characters realm to the next highest position
              sortedRealmOrGroup[sortedPosition] = toonRealm
              sortedPosition = sortedPosition + 1
            else
              -- if sorting servers and connected realms is turned on
              
              local toonRealmGroup = SI:getRealmGroup(toonRealm)
              if toonRealmGroup then 
                -- compare toon to other entries in the same realm group and sort by 
                -- string value.
                -- minimumByRealmGroup = minimumByRealmGroup or {}
                if not minRealmForGroup[toonRealmGroup] 
                  or toonRealm < minRealmForGroup[toonRealmGroup] 
                then
                  -- new lowest sorted realm in group
                  minRealmForGroup[toonRealmGroup] = toonRealm 
                end
                -- keep track of the position that this realm group will be sorted to.
                currGroupPosition = sortedPosition
                sortedRealmOrGroup[sortedPosition] = toonRealmGroup
                sortedPosition = sortedPosition + 1
              else -- if no groupID
                currGroupPosition = sortedPosition
                -- use realm name instead of groupID.
                sortedRealmOrGroup[sortedPosition] = toonRealm
                sortedPosition = sortedPosition + 1

              end
              if tooltipOptions.ConnectedRealms == "group" then
                sortedRealmOrGroup[sortedPosition] = toonRealm
                sortedPosition = sortedPosition + 1
              end
            end
          end
          --- whats the point of all the work above if we might just gonna overWrite it with order?
    
          -- insert the order of the current character into the next highest position
          sortedRealmOrGroup[sortedPosition] = characterStore.Order
          sortedPosition = sortedPosition + 1
          
          -- insert the current character Name into the next highest position
          sortedRealmOrGroup[sortedPosition] = characterKey
          sortEntries[nextIndex] = sortedRealmOrGroup
          nextIndex = nextIndex + 1
        end
      end
      
      -- On a second pass, replace the realm group index with the lowest alphabetically sorted realm in the group for that groupIdx.
      if currGroupPosition then 
        for _, sortedRealms in ipairs(sortEntries) do
          local groupID = sortedRealms[currGroupPosition]
          -- check for number incase of its a serverName entry (string)
          if type(groupID) == "number" then
            sortedRealms[currGroupPosition] = minRealmForGroup[groupID]
          end
        end
        ---@cast sortEntries table<integer, string>>[]
      end
      -- sort the `sortedRealms` entries tables of `sortEntries` by the min realm name of each group.
      table.sort(sortEntries, cpairs_sort)
      -- SI:Debug(cnext_list)
    end
    nextIndex = 1
    return cnext, characters, nil
  end
end
SI.cpairs = cpairs

-----------------------------------------------------------------------------------------------
-- tooltip event handlers

local function OpenWeeklyRewards()
  if not SI.isRetail then return end
  if WeeklyRewardsFrame and WeeklyRewardsFrame:IsVisible() then return end

  if not C_AddOns.IsAddOnLoaded('Blizzard_WeeklyRewards') then
    C_AddOns.LoadAddOn('Blizzard_WeeklyRewards')
  end
  WeeklyRewardsFrame:Show()
end

local function OpenLFD(self, instanceid, button)
  if LFDParentFrame and LFDParentFrame:IsVisible() and LFDQueueFrame.type ~= instanceid then
  -- changing entries
  else
    ToggleLFDParentFrame()
  end
  if LFDParentFrame and LFDParentFrame:IsVisible() and LFDQueueFrame_SetType then
    LFDQueueFrame_SetType(instanceid)
  end
end

local function OpenLFR(self, instanceid, button)
  if RaidFinderFrame and RaidFinderFrame:IsVisible() and RaidFinderQueueFrame.raid ~= instanceid then
  -- changing entries
  else
    PVEFrame_ToggleFrame("GroupFinderFrame", RaidFinderFrame)
  end
  if RaidFinderFrame and RaidFinderFrame:IsVisible() and RaidFinderQueueFrame_SetRaid then
    RaidFinderQueueFrame_SetRaid(instanceid)
  end
end

local function ReportKeys(self, index, button)
  if SI.isRetail and MythicPlus then 
    ---@diagnostic disable-next-line: undefined-field
    MythicPlus:Keys(index)
  end
end

local function OpenCurrency(self, _, button)
  if SI.isClassicEra then return end
  ToggleCharacter("TokenFrame")
end

local function ChatLink(self, link, button)
  if not link then return end
  if ChatEdit_GetActiveWindow() then
    ChatEdit_InsertLink(link)
  else
    ChatFrame_OpenChat(link, DEFAULT_CHAT_FRAME)
  end
end

local CloseTooltips = Tooltip.CloseIndicatorTip

local function DoNothing() end

-----------------------------------------------------------------------------------------------

local function isShowAllPressed()
  return (IsAltKeyDown() and true) or false
end

-- cache of columns allocated for either; the base state of the tootlip or the ShowAll state. Keyed by `isShowAllPressed()`
-- inner tables are key by a toon's name and the value is a boolean if its shown for that tooltip state
---@type table<boolean, table<string, boolean>>
local columnCache = { [true] = {} , [false] = {} }

local function addColumns(columns, toon, tooltip)
  ---@cast tooltip QTip
  for c = 1, MAX_COL_PER_CHARACTER do
    columns[toon..c] = columns[toon..c] or tooltip:AddColumn("CENTER")
  end
  columnCache[isShowAllPressed()][toon] = true
  -- SI:Debug("Allocated columns for %s | stack: %s ",toon, debugstack())
end
SI.scaleCache = {}

--- The function responsible for generating the addons main tooltip
---@param anchor Frame
function SI:ShowTooltip(anchor)
  local shouldShowAll = isShowAllPressed()
  if Tooltip:IsTooltipShown() and
    SI.showall == shouldShowAll and
    SI.scale == (SI.scaleCache[shouldShowAll] or SI.db.Tooltip.Scale)
  then
    return -- skip update
  end
  local starttime = debugprofilestop()
  SI.showall = shouldShowAll
  local showexpired = shouldShowAll or SI.db.Tooltip.ShowExpired
  local tooltip = Tooltip:AcquireTooltip()
  tooltip:SetCellMarginH(0)
  tooltip.anchorframe = anchor
  tooltip:SetScript("OnUpdate", UpdateTooltip)
  tooltip:Clear()
  SI.scale = SI.scaleCache[shouldShowAll] or SI.db.Tooltip.Scale
  tooltip:SetScale(SI.scale)
  SI:HistoryUpdate()
  local headText
  if SI.histLiveCount and SI.histLiveCount > 0 then
    headText = string.format("\124c%s%s (%d/%s)%s",GOLD:GenerateHexColor(),"SavedInstances",SI.histLiveCount,(SI.histOldest or "?"),FONTEND)
  else
    headText = string.format("\124c%s%s%s",GOLD:GenerateHexColor(),"SavedInstances",FONTEND)
  end
  local headLine = tooltip:AddHeader(headText)
  SI:Debug("Setting mouseover script")
  tooltip:SetCellScript(headLine, 1, "OnEnter", hoverTooltip.ShowAccountSummary )

  tooltip:SetCellScript(headLine, 1, "OnLeave", CloseTooltips)
  if SI.isRetail then 
    tooltip:SetCellScript(headLine, 1, "OnMouseDown", OpenWeeklyRewards) 
  end
  SI:UpdateToonData()
  local characterColumns = localarr("columns")
  for toon,_ in cpairs(columnCache[shouldShowAll]) do
    addColumns(characterColumns, toon, tooltip)
    columnCache[shouldShowAll][toon] = false
  end
  -- allocating columns for characters
  for toon, _ in cpairs(SI.db.Toons) do
    if SI.db.Toons[toon].Show == "always" or
      (toon == SI.thisToon and SI.db.Tooltip.SelfAlways) then
      addColumns(characterColumns, toon, tooltip)
    end
  end
  -- determining how many instances will be displayed per category
  local categoryshown = localarr("categoryshown") -- remember if each category will be shown
  local instancesSaved = localarr("instancesaved") -- remember if each instance has been saved or not (boolean)
  local combineWBs = SI.db.Tooltip.CombineWorldBosses
  local worldBosses = combineWBs and localarr("worldbosses")
  local alwaysShowWB = false
  local combineLFR = SI.db.Tooltip.CombineLFR
  local lfrBox = combineLFR and localarr("lfrbox")
  local lfrMap = combineLFR and localarr("lfrmap")
  local orderedCategories = SI:OrderedCategories()
  for _, category in ipairs(orderedCategories) do
    -- SI:Debug("category %s",category)
    for _, instanceKey in ipairs(SI:OrderedInstances(category)) do
      local instanceEntry = SI.db.Instances[instanceKey]
      if instanceEntry.Show == "always" then
        categoryshown[category] = true
      end
      if instanceEntry.Show ~= "never" then
        if worldBosses and instanceEntry.WorldBoss 
        and instanceEntry.Expansion <= GetExpansionLevel()
        then
          if SI.db.Tooltip.ReverseInstances then
            table.insert(worldBosses, instanceKey)
          else
            table.insert(worldBosses, 1, instanceKey)
          end
          alwaysShowWB = alwaysShowWB or (instanceEntry.Show == "always")
        end
        local lfrInstance = combineLFR and instanceEntry.lfgDungeonID 
                        and SI.LFRInstances[instanceEntry.lfgDungeonID]
        local lfrBoxID
        if lfrInstance then
          lfrBoxID = lfrInstance.parent
          lfrMap[instanceEntry.lfgDungeonID] = instanceKey
          if instanceEntry.Show == "always" then
            lfrBox[lfrBoxID] = true
          end
        end

        -- still unsure about cpairs
        for toon, t in cpairs(SI.db.Toons, true) do
          ---@cast toon string
          for diffID = 1, MAX_DIFFICULTY_ID do
            if instanceEntry[toon] and instanceEntry[toon][diffID] then
              local expiry = instanceEntry[toon][diffID].Expires
              if shouldShowAll then 
                categoryshown[category] = true
              elseif not shouldShowAll 
                and (expiry > 0) 
              then
                categoryshown[category] = true

                SI:Debug("Lockouts Found: %s - %s | expires in: %s " ,
                toon, instanceEntry[toon][diffID].Link or "no link",
                SecondsToTime(instanceEntry[toon][diffID].Expires - time())
              )

                if lfrInstance then
                  lfrBox[lfrBoxID] = true
                  instancesSaved[lfrBoxID] = true
                elseif combineWBs and instanceEntry.WorldBoss then
                  instancesSaved[L["World Bosses"]] = true
                else
                  instancesSaved[instanceKey] = true
                end
              end
            end
          end
        end
      end
    end
  end
  local categories = 0
  -- determining how many categories have instances that will be shown
  if SI.db.Tooltip.ShowCategories then
    for _, shown in pairs(categoryshown) do
      if shown then categories = categories + 1 end
    end
  end
  -- allocating tooltip space for instances, categories, and space between categories
  local categoryrow = localarr("categoryrow") -- remember where each category heading goes
  local instancerow = localarr("instancerow") -- remember where each instance goes
  local blankrow = localarr("blankrow") -- track blank lines
  local firstcategory = true -- use this to skip spacing before the first category
  local function addsep()
    if firstcategory then
      firstcategory = false
    else
      local line = tooltip:AddSeparator(6,0,0,0,0)
      blankrow[line] = true
    end
  end
  for _, category in ipairs(orderedCategories) do
    if categoryshown[category] then
      if SI.db.Tooltip.CategorySpaces then
        addsep()
      end
      if (categories > 1 or SI.db.Tooltip.ShowSoloCategory) and categoryshown[category] then
        local line = tooltip:AddLine()
        categoryrow[category] = line
        blankrow[line] = true
      end
      for _, instance in ipairs(SI:OrderedInstances(category)) do
        local inst = SI.db.Instances[instance]
        if not (combineWBs and inst.WorldBoss) and
          not (combineLFR and SI.LFRInstances[inst.lfgDungeonID]) then
          if inst.Show == "always" then
            instancerow[instance] = instancerow[instance] or tooltip:AddLine()
          end
          if inst.Show ~= "never" then
            for toon, t in cpairs(SI.db.Toons, true) do
              for diff = 1, MAX_DIFFICULTY_ID do
                if inst[toon] and inst[toon][diff] and (inst[toon][diff].Expires > 0 or showexpired) then
                  instancerow[instance] = instancerow[instance] or tooltip:AddLine()
                  addColumns(characterColumns, toon, tooltip)
                end
              end
            end
          end
        end
        if combineLFR and inst.lfgDungeonID then
          -- check if this parent instance has corresponding lfrboxes, and create them
          if lfrBox[inst.lfgDungeonID] then
            lfrBox[L["LFR"]..": "..instance] = tooltip:AddLine()
          end
          lfrBox[inst.lfgDungeonID] = nil
        end
      end
    end
  end
  -- now printing instance data
  for instance, row in pairs(instancerow) do
    local inst = SI.db.Instances[instance]
    tooltip:SetCell(
      row, 1, 
      (instancesSaved[instance] and GOLD or GRAY)
        :WrapTextInColorCode(instance)
    )
    -- nil check for WoTLK
    if SI.LFRInstances and SI.LFRInstances[inst.lfgDungeonID] then
      tooltip:SetLineScript(row, "OnMouseDown", OpenLFR, inst.lfgDungeonID)
    end
    for toon, t in cpairs(SI.db.Toons, true) do
      if inst[toon] then
        local showcol = localarr("showcol")
        local showcnt = 0
        for diff = 1, MAX_DIFFICULTY_ID do
          if inst[toon][diff] and (inst[toon][diff].Expires > 0 or showexpired) then
            showcnt = showcnt + 1
            showcol[diff] = true
          end
        end 
        local base = 1
        local span = MAX_COL_PER_CHARACTER
        if showcnt > 1 then
          span = 1
        end
        if showcnt > MAX_COL_PER_CHARACTER then
          SI:BugReport("Column overflow! showcnt="..showcnt)
        end
        for diffID = 1, MAX_DIFFICULTY_ID do
          if showcol[diffID] then
            local col = characterColumns[toon..base]
            tooltip:SetCell(row, col,
              DifficultyString(instance, diffID, toon, inst[toon][diffID].Expires == 0), nil, nil, span)
            tooltip:SetCellScript(row, col, "OnEnter", hoverTooltip.ShowIndicatorTooltip, {instance, toon, diffID})
            tooltip:SetCellScript(row, col, "OnLeave", CloseTooltips)
            if SI.LFRInstances[inst.lfgDungeonID] then
              tooltip:SetCellScript(row, col, "OnMouseDown", OpenLFR, inst.lfgDungeonID)
            else
              local link = inst[toon][diffID].Link
              if link then
                tooltip:SetCellScript(row, col, "OnMouseDown", ChatLink, link)
              end
              if SI.isClassicEra and toon == SI.thisToon then
                tooltip:SetCellScript(row, col, "OnMouseDown",
                  function()
                    if GetNumSavedInstances() > 0 then
                      ---@diagnostic disable-next-line: undefined-global
                      OpenFriendsFrame(FRIEND_TAB_RAID)
                      RaidInfoFrame:Show()
                    end
                  end)
              end
            end
            base = base + 1
          elseif characterColumns[toon..diffID] and showcnt > 1 then
            tooltip:SetCell(row, characterColumns[toon..diffID], "")
          end
        end
      end
    end
  end

  -- combined LFRs
  if combineLFR then
    for boxname, line in pairs(lfrBox) do
      if type(boxname) == "number" then
        SI:BugReport("Unrecognized LFR instance parent id= "..boxname)
        lfrBox[boxname] = nil
      end
    end
    for boxname, line in pairs(lfrBox) do
      local boxtype, pinstance = boxname:match("^([^:]+): (.+)$")
      local pinst = SI.db.Instances[pinstance]
      local boxid = pinst.lfgDungeonID
      local firstid
      local total = 0
      local flag = false -- flag for LFRs that are different between two factions
      local tbl, other = {}, {}
      for lfdid, lfrinfo in pairs(SI.LFRInstances) do
        if lfrinfo.parent == pinst.lfgDungeonID and lfrMap[lfdid] then
          if (not lfrinfo.faction) or (lfrinfo.faction == UnitFactionGroup("player")) then
            firstid = math.min(lfdid, firstid or lfdid)
          end
          if lfrinfo.faction and lfrinfo.faction == "Horde" then
            flag = true
            other[lfrinfo.base] = lfrMap[lfdid]
          else
            -- count total bosses for only one faction
            total = total + lfrinfo.total
            tbl[lfrinfo.base] = lfrMap[lfdid]
          end
        end
      end
      tooltip:SetCell(line, 1, (instancesSaved[boxid] and GOLD or GRAY):WrapTextInColorCode(boxname))
      tooltip:SetLineScript(line, "OnMouseDown", OpenLFR, firstid)
      for toon, t in cpairs(SI.db.Toons, true) do
        local saved = 0
        local diff = 2
        local curr = (flag and t.Faction == "Horde") and other or tbl
        for key, instance in pairs(curr) do
          saved = saved + SI:GetInstanceEncounterProgress(instance, toon, diff)
        end
        if saved > 0 then
          addColumns(characterColumns, toon, tooltip)
          local col = characterColumns[toon..1]
          tooltip:SetCell(line, col, DifficultyString(pinstance, diff, toon, false, saved, total),nil,nil,4)
          tooltip:SetCellScript(line, col, "OnEnter", hoverTooltip.ShowLFRTooltip, {boxname, toon, curr})
          tooltip:SetCellScript(line, col, "OnLeave", CloseTooltips)
        end
      end
    end
  end

  -- combined world bosses
  if worldBosses and next(worldBosses) and (alwaysShowWB or instancesSaved[L["World Bosses"]]) then
    if SI.db.Tooltip.CategorySpaces then
      addsep()
    end
    local line = tooltip:AddLine((instancesSaved[L["World Bosses"]] and LIGHTYELLOW or GRAY):WrapTextInColorCode(L["World Bosses"]))
    for toon, t in cpairs(SI.db.Toons, true) do
      local saved = 0
      local diff = 2
      for _, instance in ipairs(worldBosses) do
        local inst = SI.db.Instances[instance]
        if inst[toon] and inst[toon][diff] and inst[toon][diff].Expires > 0 then
          saved = saved + 1
        end
      end
      if saved > 0 then
        addColumns(characterColumns, toon, tooltip)
        local col = characterColumns[toon..1]
        tooltip:SetCell(line, col, DifficultyString(worldBosses[1], diff, toon, false, saved, #worldBosses),nil,nil,4)
        tooltip:SetCellScript(line, col, "OnEnter", hoverTooltip.ShowWorldBossTooltip, {worldBosses, toon, saved})
        tooltip:SetCellScript(line, col, "OnLeave", CloseTooltips)
      end
    end
  end

  local holidayinst = localarr("holidayinst")
  local firstlfd = true
  for instance, info in pairs(SI.db.Instances) do
    if shouldShowAll or
      (info.Holiday and SI.db.Tooltip.ShowHoliday) or
      (info.Random and SI.db.Tooltip.ShowRandom) then
      for toon, t in cpairs(SI.db.Toons, true) do
        local d = info[toon] and info[toon][1]
        if d then
          addColumns(characterColumns, toon, tooltip)
          local row = holidayinst[instance]
          if not row then
            if SI.db.Tooltip.CategorySpaces and firstlfd then
              addsep()
              firstlfd = false
            end
            row = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(abbreviate(instance)))
            holidayinst[instance] = row
          end
          local tstr = SecondsToTime(d.Expires - time(), false, false, 1)
          tooltip:SetCell(row, characterColumns[toon..1], ClassColorise(t.Class,tstr),nil,"CENTER",MAX_COL_PER_CHARACTER)
          tooltip:SetLineScript(row, "OnMouseDown", OpenLFD, info.lfgDungeonID)
        end
      end
    end
  end

  -- random dungeon
  if SI.db.Tooltip.TrackLFG or shouldShowAll then
    ---@type boolean|number, boolean|number
    local cd1,cd2 = false,false
    for toon, t in cpairs(SI.db.Toons, true) do
      cd2 = cd2 or t.LFG2
      cd1 = cd1 or (t.LFG1 and (not t.LFG2 or shouldShowAll))
      if t.LFG1 or t.LFG2 then
        addColumns(characterColumns, toon, tooltip)
      end
    end
    local randomLine
    if cd1 or cd2 then
      if SI.db.Tooltip.CategorySpaces and firstlfd then
        addsep()
        firstlfd = false
      end
      local cooldown = ITEM_COOLDOWN_TOTAL:gsub("%%s",""):gsub("%p","")
      cd1 = cd1 
        and tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(LFG_TYPE_RANDOM_DUNGEON..cooldown))
      cd2 = cd2 
        and tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(GetSpellInfo(71041)))
    end
    for toon, t in cpairs(SI.db.Toons, true) do
      local d1 = (t.LFG1 and t.LFG1 - time()) or -1
      local d2 = (t.LFG2 and t.LFG2 - time()) or -1
      if d1 > 0 and (d2 < 0 or shouldShowAll) then
        local col = characterColumns[toon..1]
        local tstr = SecondsToTime(d1, false, false, 1)
        tooltip:SetCell(cd1, col, ClassColorise(t.Class,tstr), nil, "CENTER",MAX_COL_PER_CHARACTER)
        tooltip:SetCellScript(cd1, col, "OnEnter", hoverTooltip.ShowSpellIDTooltip, {toon,-1,tstr})
        tooltip:SetCellScript(cd1, col, "OnLeave", CloseTooltips)
      end
      if d2 > 0 then
        local col = characterColumns[toon..1]
        local tstr = SecondsToTime(d2, false, false, 1)
        tooltip:SetCell(cd2, col, ClassColorise(t.Class,tstr), nil, "CENTER",MAX_COL_PER_CHARACTER)
        tooltip:SetCellScript(cd2, col, "OnEnter", hoverTooltip.ShowSpellIDTooltip, {toon,71041,tstr})
        tooltip:SetCellScript(cd2, col, "OnLeave", CloseTooltips)
      end
    end
  end
  if SI.db.Tooltip.TrackDeserter or shouldShowAll then
    ---@type boolean|number
    local show = false
    for toon, t in cpairs(SI.db.Toons, true) do
      if t.pvpdesert then
        show = true
        addColumns(characterColumns, toon, tooltip)
      end
    end
    if show then
      if SI.db.Tooltip.CategorySpaces and firstlfd then
        addsep()
        firstlfd = false
      end
      show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(DESERTER))
    end
    for toon, t in cpairs(SI.db.Toons, true) do
      if t.pvpdesert and time() < t.pvpdesert then
        local col = characterColumns[toon..1]
        local tstr = SecondsToTime(t.pvpdesert - time(), false, false, 1)
        tooltip:SetCell(show --[[@as number]], col, ClassColorise(t.Class,tstr),nil, "CENTER",MAX_COL_PER_CHARACTER)
        tooltip:SetCellScript(show --[[@as number]], col, "OnEnter", hoverTooltip.ShowSpellIDTooltip, {toon,26013,tstr})
        tooltip:SetCellScript(show --[[@as number]], col, "OnLeave", CloseTooltips)
      end
    end
  end

  do -- Dailies/Weeklies/DMF
    local showDailies, showWeeklies, showDMF
    for toonName, t in cpairs(SI.db.Toons, true) do
      local dailyCount, weeklyCount, dmfCount = SI:QuestCount(toonName)
      if dailyCount > 0 and (SI.db.Tooltip.TrackDailyQuests or shouldShowAll) then
        showDailies = true
        addColumns(characterColumns, toonName, tooltip)
      end
      if weeklyCount > 0 and (SI.db.Tooltip.TrackWeeklyQuests or shouldShowAll) then
        showWeeklies = true
        addColumns(characterColumns, toonName, tooltip)
      end
      if dmfCount > 0 and (SI.db.Tooltip.TrackDarkmoonQuests or shouldShowAll) then
        showDMF = true
        addColumns(characterColumns, toonName, tooltip)
      end
    end
    local adc, awc = SI:QuestCount(nil)
    if adc > 0 and (SI.db.Tooltip.TrackDailyQuests or shouldShowAll) then showDailies = true end
    if awc > 0 and (SI.db.Tooltip.TrackWeeklyQuests or shouldShowAll) then showWeeklies = true end
    if SI.db.Tooltip.CategorySpaces and (showDailies or showWeeklies) then
      addsep()
    end
    if showDailies then
      showDailies = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Daily Quests"] .. (adc > 0 and " ("..adc..")" or "")))
      if adc > 0 then
        tooltip:SetCellScript(showDailies, 1, "OnEnter", hoverTooltip.ShowQuestTooltip, {nil,adc,"daily"})
        tooltip:SetCellScript(showDailies, 1, "OnLeave", CloseTooltips)
      end
    end
    if showWeeklies then
      showWeeklies = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Weekly Quests"] .. (awc > 0 and " ("..awc..")" or "")))
      if awc > 0 then
        tooltip:SetCellScript(showWeeklies, 1, "OnEnter", hoverTooltip.ShowQuestTooltip, {nil,awc,"weekly"})
        tooltip:SetCellScript(showWeeklies, 1, "OnLeave", CloseTooltips)
      end
    end
    for toon, t in cpairs(SI.db.Toons, true) do
      local dc, wc, dmfCount = SI:QuestCount(toon)
      local col = characterColumns[toon..1]
      if showDailies and col and dc > 0 then
        tooltip:SetCell(showDailies, col, ClassColorise(t.Class,dc),nil, "CENTER",MAX_COL_PER_CHARACTER)
        tooltip:SetCellScript(showDailies, col, "OnEnter", hoverTooltip.ShowQuestTooltip, {toon,dc,"daily"})
        tooltip:SetCellScript(showDailies, col, "OnLeave", CloseTooltips)
      end
      if showWeeklies and col and wc > 0 then
        tooltip:SetCell(showWeeklies, col, ClassColorise(t.Class,wc),nil, "CENTER",MAX_COL_PER_CHARACTER)
        tooltip:SetCellScript(showWeeklies, col, "OnEnter", hoverTooltip.ShowQuestTooltip, {toon,wc,"weekly"})
        tooltip:SetCellScript(showWeeklies, col, "OnLeave", CloseTooltips)
      end
    end

    if showDMF then
      showDMF = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Darkmoon Quests"]))
      for toon, t in cpairs(SI.db.Toons, true) do
        local _, _, dmfCount = SI:QuestCount(toon)
        local col = characterColumns[toon..1]
        if col and dmfCount > 0 then
          tooltip:SetCell(showDMF, col, ClassColorise(t.Class,dmfCount),nil, "CENTER",MAX_COL_PER_CHARACTER)
          tooltip:SetCellScript(showDMF, col, "OnEnter", hoverTooltip.ShowQuestTooltip, {toon,dmfCount,"Darkmoon"})
          tooltip:SetCellScript(showDMF, col, "OnLeave", CloseTooltips)
        end
      end
    end
  end

  Progress:ShowTooltip(tooltip, characterColumns, shouldShowAll, function()
    if SI.db.Tooltip.CategorySpaces then
      addsep()
    end
    if SI.db.Tooltip.ShowCategories then
      tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Quest progresses"]))
    end
  end)

  -- Retail Specific Modules
  if SI.isRetail then
    --- Warfronts
    ---@diagnostic disable-next-line: undefined-field
    if Warfront then Warfront:ShowTooltip(tooltip, characterColumns, shouldShowAll,
      function()
        if SI.db.Tooltip.CategorySpaces then
          addsep()
        end
        if SI.db.Tooltip.ShowCategories then
          tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode( L["Warfronts"]))
        end
      end)
    end
    --- Myhtic Plus
    if SI.db.Tooltip.MythicKey or shouldShowAll then
      ---@type boolean|number
      local show = false
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.MythicKey then
          if t.MythicKey.link then
            show = true
            addColumns(characterColumns, toon, tooltip)
          end
        end
      end
      if show then
        if SI.db.Tooltip.CategorySpaces then
          addsep()
        end
        show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode( L["Mythic Keystone"]))
        tooltip:SetCellScript(show, 1, "OnEnter", hoverTooltip.ShowKeyReportTarget)
        tooltip:SetCellScript(show, 1, "OnLeave", CloseTooltips)
        tooltip:SetCellScript(show, 1, "OnMouseDown", ReportKeys, 'MythicKey')
      end
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.MythicKey and t.MythicKey.link then
          local col = characterColumns[toon..1]
          local name
          if SI.db.Tooltip.AbbreviateKeystone then
            name = SI.KeystoneAbbrev[t.MythicKey.mapID] or t.MythicKey.name
          else
            name = t.MythicKey.name
          end
          ---@cast show number
          tooltip:SetCell(show, col, "|c" .. t.MythicKey.color .. name .. " (" .. t.MythicKey.level .. ")" .. FONTEND,nil, "CENTER", MAX_COL_PER_CHARACTER)
          tooltip:SetCellScript(show, col, "OnMouseDown", ChatLink, t.MythicKey.link)
        end
      end
    end
    if SI.db.Tooltip.TimewornMythicKey or shouldShowAll then
      ---@type boolean|number
      local show = false
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.TimewornMythicKey and t.TimewornMythicKey.link then
          show = true
          addColumns(characterColumns, toon, tooltip)
        end
      end
      if show then
        if SI.db.Tooltip.CategorySpaces and not (SI.db.Tooltip.MythicKey or shouldShowAll) then
          addsep()
        end
        show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode( L["Timeworn Mythic Keystone"] ))
        tooltip:SetCellScript(show, 1, "OnEnter", hoverTooltip.ShowKeyReportTarget)
        tooltip:SetCellScript(show, 1, "OnLeave", CloseTooltips)
        tooltip:SetCellScript(show, 1, "OnMouseDown", ReportKeys, 'TimewornMythicKey')
      end
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.TimewornMythicKey and t.TimewornMythicKey.link then
          local col = characterColumns[toon..1]
          local name
          if SI.db.Tooltip.AbbreviateKeystone then
            name = SI.KeystoneAbbrev[t.TimewornMythicKey.mapID] or t.TimewornMythicKey.name
          else
            name = t.TimewornMythicKey.name
          end
          ---@cast show number
          tooltip:SetCell(show, col, "|c" .. t.TimewornMythicKey.color .. name .. " (" .. t.TimewornMythicKey.level .. ")" .. FONTEND, nil,"CENTER", MAX_COL_PER_CHARACTER)
          tooltip:SetCellScript(show, col, "OnMouseDown", ChatLink, t.TimewornMythicKey.link)
        end
      end
    end
    if SI.db.Tooltip.MythicKeyBest or shouldShowAll then
      ---@type boolean|number
      local show = false
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.MythicKeyBest then
          if t.MythicKeyBest.lastCompletedIndex or t.MythicKeyBest.rewardWaiting then
            show = true
            addColumns(characterColumns, toon, tooltip)
          end
        end
      end
      if show then
        if SI.db.Tooltip.CategorySpaces and not (SI.db.Tooltip.MythicKey or SI.db.Tooltip.TimewornMythicKey or shouldShowAll) then
          addsep()
        end
        show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Mythic Key Best"]))
      end
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.MythicKeyBest then
          local keydesc = ""
          if t.MythicKeyBest.lastCompletedIndex then
            for index = 1, t.MythicKeyBest.lastCompletedIndex do
              if t.MythicKeyBest[index] then
                keydesc = keydesc .. (index > 1 and "||" or "") .. t.MythicKeyBest[index]
              end
            end
          end
          if t.MythicKeyBest.rewardWaiting then
            if keydesc == "" then
              keydesc = SI.questTurnin
            else
              keydesc = keydesc .. "(" .. SI.questTurnin .. ")"
            end
          end
          if keydesc ~= "" then
            local col = characterColumns[toon..1]
            ---@cast show number
            tooltip:SetCell(show, col, keydesc, nil, "CENTER", MAX_COL_PER_CHARACTER)
            tooltip:SetCellScript(show, col, "OnEnter", hoverTooltip.ShowMythicPlusTooltip, {toon, keydesc})
            tooltip:SetCellScript(show, col, "OnLeave", CloseTooltips)
          end
        end
      end
    end
    --- Emissary
    local firstEmissary = true
    for expansionLevel, _ in pairs(SI.Emissaries) do
      if SI.db.Tooltip["Emissary" .. expansionLevel] or shouldShowAll then
        local day, tbl, show
        for toon, t in cpairs(SI.db.Toons, true) do
          if t.Emissary and t.Emissary[expansionLevel] and t.Emissary[expansionLevel].unlocked then
            for day, tbl in pairs(t.Emissary[expansionLevel].days) do
              if shouldShowAll or SI.db.Tooltip.EmissaryShowCompleted == true or tbl.isComplete == false then
                if not show then show = {} end
                if not show[day] then show[day] = {} end
                if not show[day][1] then
                  show[day][1] = t.Faction
                elseif show[day][1] ~= t.Faction then
                  show[day][2] = t.Faction
                end
              end
            end
          end
        end

        if show then
          if firstEmissary == true then
            if SI.db.Tooltip.CategorySpaces then
              addsep()
            end
            if SI.db.Tooltip.ShowCategories then
              tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Emissary Quests"]))
            end
            firstEmissary = false
          end

          if SI.db.Tooltip.CombineEmissary then
            local line = tooltip:AddLine(GOLD:WrapTextInColorCode(_G["EXPANSION_NAME" .. expansionLevel]))
            tooltip:SetCellScript(line, 1, "OnEnter", hoverTooltip.ShowEmissarySummary, {expansionLevel, {1, 2, 3}})
            tooltip:SetCellScript(line, 1, "OnLeave", CloseTooltips)
            for toon, t in cpairs(SI.db.Toons, true) do
              if t.Emissary and t.Emissary[expansionLevel] and t.Emissary[expansionLevel].unlocked then
                for day = 1, 3 do
                  tbl = t.Emissary[expansionLevel].days[day]
                  if tbl then
                    local col = characterColumns[toon .. day]
                    local text = ""
                    if tbl.isComplete == true then
                      text = SI.questCheckMark
                    elseif tbl.isFinish == true then
                      text = SI.questTurnin
                    else
                      text = tbl.questDone
                      if (
                        SI.db.Emissary.Expansion[expansionLevel][day] and
                        SI.db.Emissary.Expansion[expansionLevel][day].questNeed
                      ) then
                        text = text .. "/" .. SI.db.Emissary.Expansion[expansionLevel][day].questNeed
                      end
                    end
                    if col then
                      -- check if current toon is showing
                      -- don't add columns
                      tooltip:SetCell(line, col, text,nil, "CENTER", 1)
                      tooltip:SetCellScript(line, col, "OnEnter", hoverTooltip.ShowEmissaryTooltip, {expansionLevel, day, toon})
                      tooltip:SetCellScript(line, col, "OnLeave", CloseTooltips)
                    end
                  end
                end
              end
            end
          else
            for day = 1, 3 do
              if show[day] and show[day][1] then
                local name = ""
                if not SI.db.Emissary.Expansion[expansionLevel][day] then
                  name = L["Emissary Missing"]
                else
                  local length, tbl = 0, SI.db.Emissary.Expansion[expansionLevel][day].questID
                  if SI.db.Emissary.Cache[tbl[show[day][1]]] then
                    name = SI.db.Emissary.Cache[tbl[show[day][1]]]
                    length = length + 1
                  end
                  if (length == 0 or SI.db.Tooltip.EmissaryFullName) and show[day][2] then
                    if tbl[show[day][1]] ~= tbl[show[day][2]] and SI.db.Emissary.Cache[tbl[show[day][2]]] then
                      if length > 0 then
                        name = name .. " / "
                      end
                      name = name .. SI.db.Emissary.Cache[tbl[show[day][2]]]
                      length = length + 1
                    end
                  end
                  if length == 0 then
                    name = L["Emissary Missing"]
                  end
                end
                local line = tooltip:AddLine(GOLD:WrapTextInColorCode(name .. " (+" .. (day - 1) .. " " .. L["Day"] .. ")"))
                tooltip:SetCellScript(line, 1, "OnEnter", hoverTooltip.ShowEmissarySummary, {expansionLevel, {day}})
                tooltip:SetCellScript(line, 1, "OnLeave", CloseTooltips)

                for toon, t in cpairs(SI.db.Toons, true) do
                  if t.Emissary and t.Emissary[expansionLevel] and t.Emissary[expansionLevel].unlocked then
                    tbl = t.Emissary[expansionLevel].days[day]
                    if tbl then
                      local col = characterColumns[toon .. 1]
                      local text = ""
                      if tbl.isComplete == true then
                        text = SI.questCheckMark
                      elseif tbl.isFinish == true then
                        text = SI.questTurnin
                      else
                        text = tbl.questDone
                        if (
                          SI.db.Emissary.Expansion[expansionLevel][day] and
                          SI.db.Emissary.Expansion[expansionLevel][day].questNeed
                        ) then
                          text = text .. "/" .. SI.db.Emissary.Expansion[expansionLevel][day].questNeed
                        end
                      end
                      if col then
                        -- check if current toon is showing
                        -- don't add columns
                        tooltip:SetCell(line, col, text, nil, "CENTER", MAX_COL_PER_CHARACTER)
                        tooltip:SetCellScript(line, col, "OnEnter", hoverTooltip.ShowEmissaryTooltip, {expansionLevel, day, toon})
                        tooltip:SetCellScript(line, col, "OnLeave", CloseTooltips)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    --- Callings
    if SI.db.Tooltip.Calling or shouldShowAll then
      local show
      for day = 1, 3 do
        for toon, t in cpairs(SI.db.Toons, true) do
          if t.Calling and t.Calling.unlocked then
            if shouldShowAll or SI.db.Tooltip.CallingShowCompleted or (t.Calling[day] and not t.Calling[day].isCompleted) then
              if not show then show = {} end
              show[day] = true
              break
            end
          end
        end
      end
      if show then
        if SI.db.Tooltip.CategorySpaces then
          addsep()
        end
        if SI.db.Tooltip.CombineCalling then
          local line = tooltip:AddLine(GOLD:WrapTextInColorCode(CALLINGS_QUESTS))
          for toon, t in cpairs(SI.db.Toons, true) do
            if t.Calling and t.Calling.unlocked then
              for day = 1, 3 do
                local col = characterColumns[toon .. day]
                local text = ""
                if t.Calling[day].isCompleted then
                  text = SI.questCheckMark
                elseif not t.Calling[day].isOnQuest then
                  text = SI.questNormal
                elseif t.Calling[day].isFinished then
                  text = SI.questTurnin
                else
                  if t.Calling[day].objectiveType == 'progressbar' then
                    text = floor(t.Calling[day].questDone / t.Calling[day].questNeed * 100) .. "%"
                  else
                    text = t.Calling[day].questDone .. '/' .. t.Calling[day].questNeed
                  end
                end
                if col then
                  -- check if current toon is showing
                  -- don't add columns
                  tooltip:SetCell(line, col, text, nil, "CENTER", 1)
                  tooltip:SetCellScript(line, col, "OnEnter", hoverTooltip.ShowCallingTooltip, {day, toon})
                  tooltip:SetCellScript(line, col, "OnLeave", CloseTooltips)
                end
              end
            end
          end
        else
          if SI.db.Tooltip.ShowCategories then
            tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(CALLINGS_QUESTS))
          end
          for day = 1, 3 do
            if show[day] then
              local name = L["Calling Missing"]
              -- try current toon first
              local t = SI.db.Toons[SI.thisToon]
              if t and t.Calling and t.Calling[day] and t.Calling[day].title then
                name = t.Calling[day].title
              else
                for _, t in pairs(SI.db.Toons) do
                  if t.Calling and t.Calling[day] and t.Calling[day].title then
                    name = t.Calling[day].title
                    break
                  end
                end
              end
              local line = tooltip:AddLine(
                GOLD:WrapTextInColorCode(name .. " (+" .. (day - 1) .. " " .. L["Day"] .. ")")
              )
              for toon, t in cpairs(SI.db.Toons, true) do
                if t.Calling and t.Calling.unlocked then
                  local col = characterColumns[toon .. 1]
                  local text = ""
                  if t.Calling[day].isCompleted then
                    text = SI.questCheckMark
                  elseif not t.Calling[day].isOnQuest then
                    text = SI.questNormal
                  elseif t.Calling[day].isFinished then
                    text = SI.questTurnin
                  else
                    if t.Calling[day].objectiveType == 'progressbar' then
                      text = floor(t.Calling[day].questDone / t.Calling[day].questNeed * 100) .. "%"
                    else
                      text = t.Calling[day].questDone .. '/' .. t.Calling[day].questNeed
                    end
                  end
                  if col then
                    -- check if current toon is showing
                    -- don't add columns
                    tooltip:SetCell(line, col, text, nil, "CENTER", MAX_COL_PER_CHARACTER)
                    tooltip:SetCellScript(line, col, "OnEnter", hoverTooltip.ShowCallingTooltip, {day, toon})
                    tooltip:SetCellScript(line, col, "OnLeave", CloseTooltips)
                  end
                end
              end
            end
          end
        end
      end
    end
    --- Reputation Paragon Chests 
    if SI.db.Tooltip.TrackParagon or shouldShowAll then
      local show
      for toon, t in cpairs(SI.db.Toons, true) do
        if t.Paragon and #t.Paragon > 0 then
          show = true
          addColumns(characterColumns, toon, tooltip)
        end
      end
      if show then
        if SI.db.Tooltip.CategorySpaces then
          addsep()
        end
        show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Paragon Chests"]))
        for toon, t in cpairs(SI.db.Toons, true) do
          if t.Paragon and #t.Paragon > 0 then
            local col = characterColumns[toon..1]
            tooltip:SetCell(show, col, #t.Paragon, nil, "CENTER", MAX_COL_PER_CHARACTER)
            tooltip:SetCellScript(show, col, "OnEnter", hoverTooltip.ShowParagonTooltip, toon)
            tooltip:SetCellScript(show, col, "OnLeave", CloseTooltips)
          end
        end
      end
    end
  end

  --- Bonus Rolls
  if BonusRolls and (SI.db.Tooltip.TrackBonus or shouldShowAll) then
    local show
    local toonbonus = localarr("toonbonus")
    for toon, t in cpairs(SI.db.Toons, true) do
      local count = BonusRolls:GetCharacterBadLuckStreak(toon)
      if count then
        toonbonus[toon] = count
        show = true
      end
    end
    if show then
      if SI.db.Tooltip.CategorySpaces then
        addsep()
      end
      show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Roll Bonus"]))
    end
    for toon, t in cpairs(SI.db.Toons, true) do
      if toonbonus[toon] then
        local col = characterColumns[toon .. 1]
        local str = toonbonus[toon]
        if str > 0 then str = "+" .. str end
        if col then
          -- check if current toon is showing
          -- don't add columns
          tooltip:SetCell(show, col, ClassColorise(t.Class, str), nil, "CENTER", MAX_COL_PER_CHARACTER)
          tooltip:SetCellScript(show, col, "OnEnter", hoverTooltip.ShowBonusTooltip, toon)
          tooltip:SetCellScript(show, col, "OnLeave", CloseTooltips)
        end
      end
    end
  end

  -- Trade/Proffession CD's
  if SI.db.Tooltip.TrackSkills or shouldShowAll then
    ---@type boolean|number
    local show = false
    for toon, t in cpairs(SI.db.Toons, true) do
      if t.Skills and next(t.Skills) then
        show = true
        addColumns(characterColumns, toon, tooltip)
      end
    end
    if show then
      if SI.db.Tooltip.CategorySpaces then
        addsep()
      end
      show = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(L["Trade Skill Cooldowns"]))
    end
    for toon, t in cpairs(SI.db.Toons, true) do
      local cnt = 0
      if t.Skills then
        for _ in pairs(t.Skills) do cnt = cnt + 1 end
      end
      if cnt > 0 then
        local col = characterColumns[toon..1]
        ---@cast show number
        tooltip:SetCell(show, col, ClassColorise(t.Class,cnt), nil,"CENTER",MAX_COL_PER_CHARACTER)
        tooltip:SetCellScript(show, col, "OnEnter", hoverTooltip.ShowSkillTooltip, {toon, cnt})
        tooltip:SetCellScript(show, col, "OnLeave", CloseTooltips)
      end
    end
  end
  -- World Buffs
  if (SI.db.Tooltip.TrackWorldBuffs or shouldShowAll)
  and WorldBuffs 
  then
    local isCategoryShownYet = false
    local shouldAddSep = SI.db.Tooltip.CategorySpaces
    local rowIdx 
    local colIdx
    local shouldShowForCharacter = function(toon)
      -- show when already allocated(ie already shown)
      if characterColumns[toon..1] then return true end

      -- or meets show conditions
      
    end
    for toon, store in cpairs(SI.db.Toons, true) do
      if store.WorldBuffs and next(store.WorldBuffs) then
        local numCharBuffs = 0
        for _, buffInfo in pairs(store.WorldBuffs) do
          -- check for table since the boonCooldownExpiry (number) is now also stored in the table
          if type(buffInfo) == "table" then
            numCharBuffs = numCharBuffs + 1
          end
        end 

        if numCharBuffs > 0 
        -- only show alts only when theyre already being shown in the tooltip. 
        -- (ie column alrdy allocated for them)
        and (characterColumns[toon..1] or shouldShowAll)
        then
          if not isCategoryShownYet then
            if shouldAddSep then addsep() end
            rowIdx = tooltip
              :AddLine(LIGHTYELLOW:WrapTextInColorCode(L["World Buffs"]));
            isCategoryShownYet = true
          end
            addColumns(characterColumns, toon, tooltip)
            colIdx = characterColumns[toon..1]
            tooltip:SetCell(rowIdx, colIdx, ClassColorise(store.Class, numCharBuffs), nil, "CENTER", MAX_COL_PER_CHARACTER)
            tooltip:SetCellScript(rowIdx, colIdx, "OnEnter",
              function()
                WorldBuffs:ShowCharacterTooltip(toon)
              end)
            tooltip:SetCellScript(rowIdx, colIdx, "OnLeave", CloseTooltips)
          end
      end
    end
  end
  -- Currencies 
  local firstcurrency = true
  local currencies = Currency:GetCurrencyList(SI.db.Tooltip.CurrencySortName)
  local shouldShowOnAll = function(currencyID)
    if SI.isRetail then return true end -- retain old functionality in retail clients
    assert(
      type(SI.db.Tooltip.CurrencyHideUntracked) == "boolean", 
      "CurrencyHideUntracked must be defined"
    )
    if not SI.db.Tooltip["Currency" .. currencyID]
      and SI.db.Tooltip.CurrencyHideUntracked
    then
      return false 
    else 
      return true 
    end

  end
  for _, currencyID in ipairs(currencies) do
    -- if currency tracked or showall pressed
    if SI.db.Tooltip["Currency" .. currencyID] 
    or (shouldShowOnAll(currencyID) and shouldShowAll)
    then
      local currencyRowLabel
      for charKey, charStore in cpairs(SI.db.Toons, true) do
        -- ci.name, ci.amount, ci.earnedThisWeek, ci.weeklyMax, ci.totalMax, ci.relatedItemCount
        ---@type SavedInstances.Toon.Currency
        local currencyStoreInfo = charStore.currency and charStore.currency[currencyID];

        if currencyStoreInfo then
          local hasWeeklyCurrencyProgress
            = ((currencyStoreInfo.earnedThisWeek or 0) > 0) and ((currencyStoreInfo.weeklyMax or 0) > 0);
          local hasCurrency
            = ((currencyStoreInfo.relatedItemCount or 0) > 0) or ((currencyStoreInfo.amount or 0) > 0);

          -- allocate column for a character to show currency info in tooltip
          -- any weekly currencies will force create a column
          -- any currency will create a column if the user has chosen to show all currencies
          if hasWeeklyCurrencyProgress 
          or (hasCurrency and shouldShowAll)
          then
            addColumns(characterColumns, charKey, tooltip)
          end
          -- only create a row entry when: 
          -- the row entry didnt already exists,
          -- and there is a currency to show for this character,
          -- and this character has a column allocated for it.
          if not currencyRowLabel 
          and (hasWeeklyCurrencyProgress or hasCurrency) 
          and characterColumns[charKey .. 1] 
          then
            local info = Currency:GetCurrencyInfo(currencyID) or {}
            currencyRowLabel = format(" \124T%s:0\124t%s", info.icon or "134400", info.name or "")
          end
        end
      end
      local currLine
      if currencyRowLabel then
        if SI.db.Tooltip.CategorySpaces and firstcurrency then
          addsep()
          firstcurrency = false
        end
        currLine = tooltip:AddLine(LIGHTYELLOW:WrapTextInColorCode(currencyRowLabel))
        tooltip:SetLineScript(currLine, "OnMouseDown", OpenCurrency)
        tooltip:SetCellScript(currLine, 1, "OnEnter", hoverTooltip.ShowCurrencySummary, currencyID)
        tooltip:SetCellScript(currLine, 1, "OnLeave", CloseTooltips)
        tooltip:SetCellScript(currLine, 1, "OnMouseDown", OpenCurrency)

        for toon, toonData in cpairs(SI.db.Toons, true) do
          local toonCurrencyInfo = toonData.currency and toonData.currency[currencyID]
          local col = characterColumns[toon..1]
          if toonCurrencyInfo and col then
            local earned, weeklymax, totalmax = "","",""
            if SI.db.Tooltip.CurrencyMax then
              if (toonCurrencyInfo.weeklyMax or 0) > 0 then
                weeklymax = "/"..SI:formatNumber(toonCurrencyInfo.weeklyMax)
              end
              if (toonCurrencyInfo.totalMax or 0) > 0 then
                totalmax = "/"..SI:formatNumber(toonCurrencyInfo.totalMax)
              end
            end
            if SI.db.Tooltip.CurrencyEarned or shouldShowAll then
              earned = CurrencyColor(toonCurrencyInfo.amount,toonCurrencyInfo.totalMax)..totalmax
            end
            local str
            if (toonCurrencyInfo.amount or 0) > 0 or (toonCurrencyInfo.earnedThisWeek or 0) > 0 or (toonCurrencyInfo.totalEarned or 0) > 0 then
              if (toonCurrencyInfo.weeklyMax or 0) > 0 then
                str = earned.." ("..CurrencyColor(toonCurrencyInfo.earnedThisWeek,toonCurrencyInfo.weeklyMax)..weeklymax..")"
              elseif (toonCurrencyInfo.amount or 0) > 0 or (toonCurrencyInfo.totalEarned or 0) > 0 then
                str = CurrencyColor(toonCurrencyInfo.amount, toonCurrencyInfo.totalMax, toonCurrencyInfo.totalEarned) .. totalmax
              end
              if SI.specialCurrency[currencyID] and SI.specialCurrency[currencyID].relatedItem then
                if SI.specialCurrency[currencyID].relatedItem.holdingMax then
                  local holdingMax = SI.specialCurrency[currencyID].relatedItem.holdingMax
                  if SI.db.Tooltip.CurrencyMax then
                    str = str .. " (" .. CurrencyColor(toonCurrencyInfo.relatedItemCount or 0, holdingMax) .. "/" .. holdingMax .. ")"
                  else
                    str = str .. " (" .. CurrencyColor(toonCurrencyInfo.relatedItemCount or 0, holdingMax) .. ")"
                  end
                else
                  str = str .. " (" .. (toonCurrencyInfo.relatedItemCount or 0) .. ")"
                end
              end
            end
            if str then
              if not SI.db.Tooltip.CurrencyValueColor then
                str = ClassColorise(toonData.Class,str)
              end
              tooltip:SetCell(currLine, col, str, nil, "CENTER", MAX_COL_PER_CHARACTER)
              tooltip:SetCellScript(currLine, col, "OnEnter", hoverTooltip.ShowCurrencyTooltip, {toon, currencyID, toonCurrencyInfo})
              tooltip:SetCellScript(currLine, col, "OnLeave", CloseTooltips)
              tooltip:SetCellScript(currLine, col, "OnMouseDown", OpenCurrency)
            end
          end
        end
      end
    end
  end

  -- Add toon names to allocated column
  for toondiff, col in pairs(characterColumns) do
    local toon = strsub(toondiff, 1, #toondiff-1)
    local diff = strsub(toondiff, #toondiff, #toondiff)
    if diff == "1" then
      local toonname, toonserver = toon:match('^(.*) [-] (.*)$')
      local toonstr = toonname
      if SI.db.Tooltip.ShowServer then
        toonstr = toonstr .. "\n" .. toonserver
      end
      tooltip:SetCell(headLine, col, ClassColorise(SI.db.Toons[toon].Class, toonstr),
        tooltip:GetHeaderFont(), "CENTER", MAX_COL_PER_CHARACTER)
      tooltip:SetCellScript(headLine, col, "OnEnter", hoverTooltip.ShowToonTooltip, toon)
      tooltip:SetCellScript(headLine, col, "OnLeave", CloseTooltips)
    end
  end


  -- we now know enough to put in the category row names where necessary
  if SI.db.Tooltip.ShowCategories then
    for category, row in pairs(categoryrow) do
      if (categories > 1 or SI.db.Tooltip.ShowSoloCategory) and categoryshown[category] then
        tooltip:SetCell(
          row, 1,
          LIGHTYELLOW:WrapTextInColorCode(INSTANCE_CATEGORY_NAMES[category]),
          nil, "LEFT", tooltip:GetColumnCount()
      )
      end
    end
  end

  local hi = true
  for i=2,tooltip:GetLineCount() do -- row highlighting
    tooltip:SetLineScript(i, "OnEnter", DoNothing)
    tooltip:SetLineScript(i, "OnLeave", DoNothing)

    if hi and not blankrow[i] then
      tooltip:SetLineColor(i, 1,1,1, SI.db.Tooltip.RowHighlight)
      hi = false
    else
      tooltip:SetLineColor(i, 0,0,0, 0)
      hi = true
    end
  end

  -- finishing up, with hints
  if TableLen(instancerow) == 0 then
    local noneLine = tooltip:AddLine()
    tooltip:SetCell(noneLine, 1, GRAY:WrapTextInColorCode(NO_RAID_INSTANCES_SAVED), nil, "LEFT", tooltip:GetColumnCount())
  end
  if SI.db.Tooltip.ShowHints then
    tooltip:AddSeparator(8,0,0,0,0)
    local hintLine, hintCol
    if not Tooltip:IsDetached() then
      hintLine, hintCol = tooltip:AddLine()
      tooltip:SetCell(hintLine, hintCol, L["|cffffff00Left-click|r to detach tooltip"], nil,"LEFT", tooltip:GetColumnCount())
      hintLine, hintCol = tooltip:AddLine()
      tooltip:SetCell(hintLine, hintCol, L["|cffffff00Middle-click|r to show Blizzard's Raid Information"], nil, "LEFT", tooltip:GetColumnCount())
      hintLine, hintCol = tooltip:AddLine()
      tooltip:SetCell(hintLine, hintCol, L["|cffffff00Right-click|r to configure SavedInstances"], nil, "LEFT", tooltip:GetColumnCount())
    end
    hintLine, hintCol = tooltip:AddLine()
    tooltip:SetCell(hintLine, hintCol, L["Hover mouse on indicator for details"], nil,"LEFT", tooltip:GetColumnCount())
    if not shouldShowAll then
      hintLine, hintCol = tooltip:AddLine()
      tooltip:SetCell(hintLine, hintCol, L["Hold Alt to show all data"], nil,"LEFT", math.max(1,tooltip:GetColumnCount()-MAX_COL_PER_CHARACTER))
      if tooltip:GetColumnCount() < MAX_COL_PER_CHARACTER+1 then
        tooltip:AddLine("SavedInstances".." version "..SI.version)
      else
        tooltip:SetCell(hintLine, tooltip:GetColumnCount()-MAX_COL_PER_CHARACTER+1, SI.version,nil, "RIGHT", MAX_COL_PER_CHARACTER)
      end
    end
  end

  -- cache check
  local fail = false
  local maxidx = 0
  for toon,val in cpairs(columnCache[shouldShowAll]) do
    if not val then -- remove stale column
      columnCache[shouldShowAll][toon] = nil
      fail = true
    else
      local thisidx = characterColumns[toon..1]
      if thisidx < maxidx then -- sort failure caused by new middle-insertion
        fail = true
      end
      maxidx = thisidx
    end
  end
  if fail then -- retry with corrected cache
    SI:Debug("Tooltip cache miss")
    ---@diagnostic disable-next-line: need-check-nil
    SI.scaleCache[shouldShowAll] = nil
    --SI:ShowTooltip(anchorframe)
    -- reschedule continuation to reduce time-slice exceeded errors in combat
    SI:ScheduleTimer("ShowTooltip", 0, anchor)
  else -- render it
    SI:SkinFrame(tooltip,"SavedInstancesTooltip")
    if Tooltip:IsDetached() then
      local detachFrame = Tooltip:GetDetachedFrame()
      tooltip:Show()
      ---@diagnostic disable-next-line: undefined-field
      QTip.layoutCleaner:CleanupLayouts()
      tooltip:ClearAllPoints()
      tooltip:SetPoint("BOTTOMLEFT", detachFrame)
      tooltip:SetFrameLevel(detachFrame:GetFrameLevel() + 1)
    else
      tooltip:SmartAnchorTo(anchor)
      tooltip:SetAutoHideDelay(0.1, anchor)
      tooltip:Show()
    end
    if SI.db.Tooltip.FitToScreen then
      -- scale check
      --todo garuntee this exists
      ---@diagnostic disable-next-line: undefined-field
      QTip.layoutCleaner:CleanupLayouts()
      local scale = tooltip:GetScale()
      local w,h = tooltip:GetSize()
      local sw,sh = UIParent:GetSize()
      w = w*scale
      h = h*scale
      if w > sw or h > sh then
        scale = scale / math.max(w/sw, h/sh)
        scale = scale*0.95 -- 5% slop to speed convergeance
        SI:Debug("Downscaling to %.4f",scale)
        tooltip:SetScale(scale)
        tooltip:Hide()
        ---@diagnostic disable-next-line: need-check-nil
        SI.scaleCache[shouldShowAll] = scale
        SI:ScheduleTimer("ShowTooltip", 0, anchor) -- re-render fonts
      end
    end
  end
  starttime = debugprofilestop()-starttime
  SI:Debug("ShowTooltip(): completed in %.3fms", starttime)
end
