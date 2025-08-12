---@type SavedInstances
local SI, L = unpack((select(2, ...)))

---@class CurrencyModule : AceModule , AceEvent-3.0, AceTimer-3.0, AceBucket-3.0
local Module = SI:NewModule('Currency', 'AceEvent-3.0', 'AceTimer-3.0', 'AceBucket-3.0')
local Expansion = SI.Enum.Expansion

Module.IsUsingCurrencyAPI = Expansion.Current >= Expansion.Wrath

-- Lua functions
local ipairs, pairs = ipairs, pairs

-- WoW API / Variables
local C_Covenants_GetActiveCovenantID = C_Covenants and C_Covenants.GetActiveCovenantID -- not in Wotlk client
local C_CurrencyInfo_GetCurrencyInfo = C_CurrencyInfo.GetCurrencyInfo
local C_QuestLog_IsQuestFlaggedCompleted = C_QuestLog.IsQuestFlaggedCompleted
local GetItemCount = GetItemCount
local GetMoney = GetMoney
-- Unused, kept for documentation purposes. only supporting classic clients now.
local retailCurrencies = {
  81, -- Epicurean Award
  515, -- Darkmoon Prize Ticket
  2588, -- Riders of Azeroth Badge
  1900, -- Arena Points
  1901, -- Honor Points

  -- Wrath of the Lich King
  61, -- Dalaran Jewelcrafter's Token
  81, -- Epicurean Award
  101, -- Emblem of Heroism
  102, -- Emblem of Valor
  126, -- Wintergrasp Mark of Honor
  161, -- Stone Keeper's Shard
  201, -- Venture Coin
  221, -- Emblem of Conquest
  241, -- Champion's Seal
  301, -- Emblem of Triumph
  341, -- Emblem of Frost
  2711, -- Defiler's Scourgestone
  2589, -- Sidereal Essence

  -- Cataclysm
  361, -- Illustrious Jewelcrafter's Token
  384, -- Dwarf Archaeology Fragment
  385, -- Troll Archaeology Fragment
  390, -- Conquest Points
  391, -- Tol Barad Commendation
  395, -- Justice Points
  396, -- Valor Points
  397, -- Orc Archaeology Fragment
  398, -- Draenei Archaeology Fragment
  399, -- Vrykul Archaeology Fragment
  400, -- Nerubian Archaeology Fragment
  401, -- Tol'vir Archaeology Fragment
  402, -- Chef's Award
  416, -- Mark of the World Tree
  614, -- Mote of Darkness
  615, -- Essence of Corrupted Deathwing

  -- Mists of Pandaria
  402, -- Ironpaw Token
  697, -- Elder Charm of Good Fortune
  738, -- Lesser Charm of Good Fortune
  752, -- Mogu Rune of Fate
  776, -- Warforged Seal
  777, -- Timeless Coin
  789, -- Bloody Coin

  -- Warlords of Draenor
  823, -- Apexis Crystal
  824, -- Garrison Resources
  994, -- Seal of Tempered Fate
  1101, -- Oil
  1129, -- Seal of Inevitable Fate
  1149, -- Sightless Eye
  1155, -- Ancient Mana
  1166, -- Timewarped Badge

  -- Legion
  1220, -- Order Resources
  1226, -- Nethershards
  1273, -- Seal of Broken Fate
  1275, -- Curious Coin
  1299, -- Brawler's Gold
  1314, -- Lingering Soul Fragment
  1342, -- Legionfall War Supplies
  1501, -- Writhing Essence
  1508, -- Veiled Argunite
  1533, -- Wakening Essence

  -- Battle for Azeroth
  1710, -- Seafarer's Dubloon
  1580, -- Seal of Wartorn Fate
  1560, -- War Resources
  1587, -- War Supplies
  1716, -- Honorbound Service Medal
  1717, -- 7th Legion Service Medal
  1718, -- Titan Residuum
  1721, -- Prismatic Manapearl
  1719, -- Corrupted Memento
  1755, -- Coalescing Visions
  1803, -- Echoes of Ny'alotha

  -- Shadowlands
  1754, -- Argent Commendation
  1191, -- Valor
  1602, -- Conquest
  1792, -- Honor
  1822, -- Renown
  1767, -- Stygia
  1828, -- Soul Ash
  1810, -- Redeemed Soul
  1813, -- Reservoir Anima
  1816, -- Sinstone Fragments
  1819, -- Medallion of Service
  1820, -- Infused Ruby
  1885, -- Grateful Offering
  1889, -- Adventure Campaign Progress
  1904, -- Tower Knowledge
  1906, -- Soul Cinders
  1931, -- Cataloged Research
  1977, -- Stygian Ember
  1979, -- Cyphers of the First Ones
  2009, -- Cosmic Flux
  2000, -- Motes of Fate

  -- Dragonflight
  2003, -- Dragon Isles Supplies
  2245, -- Flightstones
  2123, -- Bloody Tokens
  2797, -- Trophy of Strife
  2045, -- Dragon Glyph Embers
  2118, -- Elemental Overflow
  2122, -- Storm Sigil
  2409, -- Whelpling Crest Fragment Tracker [DNT]
  2410, -- Drake Crest Fragment Tracker [DNT]
  2411, -- Wyrm Crest Fragment Tracker [DNT]
  2412, -- Aspect Crest Fragment Tracker [DNT]
  2413, -- 10.1 Professions - Personal Tracker - S2 Spark Drops (Hidden)
  2533, -- Renascent Shadowflame
  2594, -- Paracausal Flakes
  2650, -- Emerald Dewdrop
  2651, -- Seedbloom
  2777, -- Dream Infusion
  2796, -- Renascent Dream
  2706, -- Whelpling's Dreaming Crest
  2707, -- Drake's Dreaming Crest
  2708, -- Wyrm's Dreaming Crest
  2709, -- Aspect's Dreaming Crest
  2774, -- 10.2 Professions - Personal Tracker - S3 Spark Drops (Hidden)
  2657, -- Mysterious Fragment
  2912, -- Renascent Awakening
  2806, -- Whelpling's Awakened Crest
  2807, -- Drake's Awakened Crest
  2809, -- Wyrm's Awakened Crest
  2812, -- Aspect's Awakened Crest
  2800, -- 10.2.6 Professions - Personal Tracker - S4 Spark Drops (Hidden)
  3010, -- 10.2.6 Rewards - Personal Tracker - S4 Dinar Drops (Hidden)
}

-- ordered list of currency categories
-- order here is used for the category display order in the currency settings
local orderedCategories = {
  -- Misc.
  BINDING_HEADER_MISC,
  -- PvP
  PLAYER_V_PLAYER,
  -- Wrath of the Lich King
  EXPANSION_NAME2,
  -- Cataclysm
  EXPANSION_NAME3,
  -- Mists of Pandaria
  EXPANSION_NAME4,
  -- Archaeology
  PROFESSIONS_ARCHAEOLOGY,
}
-- currencies used on/after wrath of the lich king
local modernClassicCurrencies = {
  -- Misc
  [BINDING_HEADER_MISC] = {
    515, -- Darkmoon Prize Ticket
  },
  -- PvP
  [PLAYER_V_PLAYER] = {
    -- 1900, -- Arena Points
    1901, -- Honor Points
    390, -- Conquest Points
  } ,
  -- Wrath of the Lich King
  [EXPANSION_NAME2] = Expansion.Current >= Expansion.Wrath and {
    61, -- Dalaran Jewelcrafter's Token
    81, -- Epicurean Award
    101, -- Emblem of Heroism
    102, -- Emblem of Valor
    126, -- Wintergrasp Mark of Honor
    161, -- Stone Keeper's Shard
    201, -- Venture Coin
    221, -- Emblem of Conquest
    241, -- Champion's Seal
    301, -- Emblem of Triumph
    341, -- Emblem of Frost
    2711, -- Defiler's Scourgestone
    2589, -- Sidereal Essence
  } or nil,
  -- Cataclysm
  [EXPANSION_NAME3] = Expansion.Current >= Expansion.Cata and {
    361, -- Illustrious Jewelcrafter's Token
    391, -- Tol Barad Commendation
    395, -- Justice Points
    396, -- Valor Points
    416, -- Mark of the World Tree
    614, -- Mote of Darkness
    615, -- Essence of Corrupted Deathwing
    3148, -- Fissure Stone Fragment
    3281, -- Obsidian Fragment
    Expansion.Current == Expansion.Cata and 402 or nil, -- Chef's Award (Moved to Ironpaw Token in Mists)
  },
  -- Mists of Pandaria
  [EXPANSION_NAME4] = Expansion.Current >= Expansion.Mists and {
    3350, -- August Stone Fragment
    402, -- Ironpaw Token
    697, -- Elder Charm of Good Fortune
    698, -- Zen Jewelcrafter's Token
    738, -- Lesser Charm of Good Fortune
    752, -- Mogu Rune of Fate
    776, -- Warforged Seal
    777, -- Timeless Coin
    789, -- Bloody Coin
  } or nil,
  -- Archaeology
  [PROFESSIONS_ARCHAEOLOGY] = Expansion.Current >= Expansion.Cata and {
    -- cataclysm
    384, -- Dwarf Archaeology Fragment
    385, -- Troll Archaeology Fragment
    397, -- Orc Archaeology Fragment
    398, -- Draenei Archaeology Fragment
    399, -- Vrykul Archaeology Fragment
    400, -- Nerubian Archaeology Fragment
    401, -- Tol'vir Archaeology Fragment
    -- mists of pandaria
    676, -- Pandaren Archaeology Fragment
    677, -- Mogu Archaeology Fragment
    754, -- Mantid Archaeology Fragment
  } or nil,
}
--- There is no designated currency api in classic. Any "currency" is just a bag item.
-- list of category names followed by currencyIds for that category
local classicEraCurrencies = {
  -- Misc
  [BINDING_HEADER_MISC] = {
    (SI.isSoD and 212160 or 184937), -- Chronoboon Displacer (SoD/Era specific)
    (SI.isSoD and 226404 or nil), -- Tarnished Undermine Real (SoD currency)
  },
  -- Holiday Currency
  [CALENDAR_FILTER_WEEKLY_HOLIDAYS] = {
    19182, -- Darkmoon Faire Prize Ticket
    21100, -- Coin of Ancestry
  },
  -- ZG Coins+Bijous
  [DUNGEON_FLOOR_ZULGURUB1] = {
    19698, -- Zulian Coin
    19699, -- Razzashi Coin
    19700, -- Hakkari Coin
    19701, -- Gurubashi Coin
    19702, -- Vilebranch Coin
    19703, -- Witherbark Coin
    19704, -- Sandfury Coin
    19705, -- Skullsplitter Coin
    19706, -- Bloodscalp Coin
    19707, -- Red Hakkari Bijou
    19708, -- Blue Hakkari Bijou
    19709, -- Yellow Hakkari Bijou
    19710, -- Orange Hakkari Bijou
    19711, -- Green Hakkari Bijou
    19712, -- Purple Hakkari Bijou
    19713, -- Bronze Hakkari Bijou
    19714, -- Silver Hakkari Bijou
    19715, -- Gold Hakkari Bijou
  },
  -- Battleground Rewards
  [BATTLEFIELDS] = {
    -- 19322, -- Warsong Mark of Honor (DEPRECATED) https://www.wowhead.com/classic/item=19322
    20558, -- Warsong Gulch Mark of Honor
    20559, -- Arathi Basin Mark of Honor
    20560, -- Alterac Valley Mark of Honor
  },
  -- AQ Scarabs + Idols
  [DUNGEON_FLOOR_RUINSOFAHNQIRAJ1] = {
    20858, -- Stone Scarab
    20859, -- Gold Scarab
    20860, -- Silver Scarab
    20861, -- Bronze Scarab
    20862, -- Crystal Scarab
    20863, -- Clay Scarab
    20864, -- Bone Scarab
    20865, -- Ivory Scarab
    20866, -- Azure Idol
    20867, -- Onyx Idol
    20868, -- Lambent Idol
    20869, -- Amber Idol
    20870, -- Jasper Idol
    20871, -- Obsidian Idol
    20872, -- Vermillion Idol
    20873, -- Alabaster Idol
    20874, -- Idol of the Sun
    20875, -- Idol of Night
    20876, -- Idol of Death
    20877, -- Idol of the Sage
    20878, -- Idol of Rebirth
    20879, -- Idol of Life
    20881, -- Idol of Strife
    20882, -- Idol of War
  },
  -- Naxx Gear Reagents
  [L["Naxxramas"]] = {
    22373, -- Wartorn Leather Scrap
    22374, -- Wartorn Chain Scrap
    22375, -- Wartorn Plate Scrap
    22376, -- Wartorn Cloth Scrap
  },
  -- Argent Dawn Related
  [L["Argent Dawn"]] = {
    12840, -- Minion's Scourgestone
    12841, -- Invader's Scourgestone
    12843, -- Corruptor's Scourgestone
    12844, -- Argent Dawn Valor Token
    22523, -- Insignia of the Dawn
    22524, -- Insignia of the Crusade
  },
  -- Silithus Quests
  [L["Silithus"]] = {
    20800, -- Cenarion Logistics Badge
    20801, -- Cenarion Tactical Badge
    20802, -- Cenarion Combat Badge
  },
  -- MC
  [DUNGEON_FLOOR_MOLTENCORE1] = {
    17333, -- Aqual Quintessence
    22754, -- Eternal Quintessence
  },
}
local classicEraCategories = {
  -- Misc.
  BINDING_HEADER_MISC,
  -- Holiday Currencies
  CALENDAR_FILTER_WEEKLY_HOLIDAYS,
  -- Battleground Rewards
  BATTLEFIELDS,
  -- Molten core currencies
  DUNGEON_FLOOR_MOLTENCORE1,
  -- ZG Coins + Bijous
  DUNGEON_FLOOR_ZULGURUB1,
  -- AQ Scarabs + Idols
  DUNGEON_FLOOR_RUINSOFAHNQIRAJ1,
  -- Naxx Gear Reagents
  L["Naxxramas"],
  -- Argent Dawn Related
  L["Argent Dawn"],
  -- Silithus Quests
  L["Silithus"],
}
--Todo(classic): Scan tooltip for unique count and saved a copy of the tooltip for each currency to show on mouseover for the currency cell in the main addon frame

local currencySorted = {} ---@type number[]
local validCurrencies = {} ---@type number[]
local categoryByCurrencyID = {}
if not Module.IsUsingCurrencyAPI then
  for categoryName, currencyItemIDs in ipairs(classicEraCurrencies) do
    for _, currencyID in ipairs(currencyItemIDs) do
      table.insert(validCurrencies, currencyID)
      table.insert(currencySorted, currencyID)
      categoryByCurrencyID[currencyID] = categoryName
    end
  end
else
  for category, currencyIDS in pairs(modernClassicCurrencies) do
    for _, currencyID in ipairs(currencyIDS) do
      if C_CurrencyInfo_GetCurrencyInfo(currencyID) then
        table.insert(validCurrencies, currencyID)
        table.insert(currencySorted, currencyID)
        categoryByCurrencyID[currencyID] = category
      end
    end
  end
end
table.sort(currencySorted, function (c1, c2)
  if not Module.IsUsingCurrencyAPI then
    local c1_name = GetItemInfo(c1) or tostring(c1)
    local c2_name = GetItemInfo(c2) or tostring(c2)
    return c1_name < c2_name
  end
  local c1_name = C_CurrencyInfo_GetCurrencyInfo(c1).name
  local c2_name = C_CurrencyInfo_GetCurrencyInfo(c2).name
  return c1_name < c2_name
end)

local hiddenCurrency = {}

---@type {[number]: {left:{ text: string, font: FontObject, color: {}}}[]}
local currencyTooltipCache = {}

-- [currencyID]: { weeklyMax, earnByQuest, relatedItem }
---@type table<number, {weeklyMax: number?, earnByQuest: number[], relatedItem: {id: number, holdingMax: number?}}>
local specialCurrencies = {
  [1129] = { -- WoD - Seal of Tempered Fate
    weeklyMax = 3,
    earnByQuest = {
      36058,  -- Seal of Dwarven Bunker
      -- Seal of Ashran quests
      36054,
      37454,
      37455,
      36056,
      37456,
      37457,
      36057,
      37458,
      37459,
      36055,
      37452,
      37453,
    },
  },
  [1273] = { -- LEG - Seal of Broken Fate
    weeklyMax = 3,
    earnByQuest = {
      43895,
      43896,
      43897,
      43892,
      43893,
      43894,
      43510, -- Order Hall
      47851, -- Mark of Honor x5
      47864, -- Mark of Honor x10
      47865, -- Mark of Honor x20
    },
  },
  [1580] = { -- BfA - Seal of Wartorn Fate
    weeklyMax = 2,
    earnByQuest = {
      52834, -- Gold
      52838, -- Piles of Gold
      52835, -- Marks of Honor
      52839, -- Additional Marks of Honor
      52837, -- War Resources
      52840, -- Stashed War Resources
    },
  },
  [1755] = { -- BfA - Coalescing Visions
    relatedItem = {
      id = 173363,
      holdingMax = nil,
    }, -- Vessel of Horrific Visions
  },
}
--- used for certain retail currencies with special properties not obtainable through APIs
SI.specialCurrency = specialCurrencies

--- add any quests related to special currencies to the QuestExceptions table
--- this is done so that they do not appear in the Weekly Quests tracker
for _, tbl in pairs(specialCurrencies) do
  if tbl.earnByQuest then
    for _, questID in ipairs(tbl.earnByQuest) do
      SI.QuestExceptions[questID] = "Regular" -- not show in Weekly Quest
    end
  end
end

Module.OverrideName = {
  [2409] = L["Loot Whelpling Crest Fragment"], -- Whelpling Crest Fragment Tracker [DNT]
  [2410] = L["Loot Drake Crest Fragment"], -- Drake Crest Fragment Tracker [DNT]
  [2411] = L["Loot Wyrm Crest Fragment"], -- Wyrm Crest Fragment Tracker [DNT]
  [2412] = L["Loot Aspect Crest Fragment"], -- Aspect Crest Fragment Tracker [DNT]
  [2413] = L["Loot Spark of Shadowflame"], -- 10.1 Professions - Personal Tracker - S2 Spark Drops (Hidden)
  [2774] = L["Loot Spark of Dreams"], -- 10.2 Professions - Personal Tracker - S3 Spark Drops (Hidden)
  [2800] = L["Loot Spark of Awakening"], -- 10.2.6 Professions - Personal Tracker - S4 Spark Drops (Hidden)
  [3010] = L["Loot Antique Bronze Bullion"], -- 10.2.6 Rewards - Personal Tracker - S4 Dinar Drops (Hidden)
}

Module.OverrideTexture = {
  [2413] = 5088829, -- 10.1 Professions - Personal Tracker - S2 Spark Drops (Hidden)
  [2774] = 5341573, -- 10.2 Professions - Personal Tracker - S3 Spark Drops (Hidden)
  [2800] = 4693222, -- 10.2.6 Professions - Personal Tracker - S4 Spark Drops (Hidden)
  [3010] = 4555657, -- 10.2.6 Rewards - Personal Tracker - S4 Dinar Drops (Hidden)
}

function Module:OnEnable()
  self:RegisterEvent("PLAYER_MONEY", function() Module:UpdatePlayerCurrencies() end)
  self:RegisterBucketEvent("CURRENCY_DISPLAY_UPDATE", 0.25, function() Module:UpdatePlayerCurrencies() end)
  self:RegisterEvent("BAG_UPDATE", function() Module:UpdateCurrencyItem() end)
end

function Module:UpdatePlayerCurrencies()
  if SI.logout then return end -- currency is unreliable during logout

  local playerStore = SI.db.Toons[SI.thisToon]
  playerStore.Money = GetMoney()
  playerStore.currency = playerStore.currency or {}

  if not Module.IsUsingCurrencyAPI then
    for _, currencyItemID in ipairs(validCurrencies) do
      ---@type SavedInstances.Toon.Currency
      local currencyInfo = playerStore.currency[currencyItemID] or {}
      currencyInfo.amount = GetItemCount(currencyItemID, true)
      currencyInfo.relatedItemCount = GetItemCount(currencyItemID, true)
      playerStore.currency[currencyItemID] = currencyInfo
    end
  else
    local covenantID = C_Covenants_GetActiveCovenantID and C_Covenants_GetActiveCovenantID()
    for _,currencyID in ipairs(validCurrencies) do
      local data = C_CurrencyInfo_GetCurrencyInfo(currencyID)
      if not data
      or (not data.discovered and not hiddenCurrency[currencyID])
      then
        playerStore.currency[currencyID] = nil
      else
        local currencyInfo = playerStore.currency[currencyID] or {}
        currencyInfo.amount = data.quantity
        currencyInfo.totalMax = data.maxQuantity
        currencyInfo.earnedThisWeek = data.quantityEarnedThisWeek
        currencyInfo.weeklyMax = data.maxWeeklyQuantity
        if data.useTotalEarnedForMaxQty then
          currencyInfo.totalEarned = data.totalEarned
        end
        -- handle special currency
        if specialCurrencies[currencyID] then
          local tbl = specialCurrencies[currencyID]
          if tbl.weeklyMax then currencyInfo.weeklyMax = tbl.weeklyMax end
          if tbl.earnByQuest then
            currencyInfo.earnedThisWeek = 0
            for _, questID in ipairs(tbl.earnByQuest) do
              if C_QuestLog_IsQuestFlaggedCompleted(questID) then
                currencyInfo.earnedThisWeek = currencyInfo.earnedThisWeek + 1
              end
            end
          end
          if tbl.relatedItem then
            currencyInfo.relatedItemCount = GetItemCount(tbl.relatedItem.id)
          end
        -- todo: remove, keeping around for reference
        -- elseif covenantID and currencyID == 1822 then -- Renown
        --   -- plus one to amount and totalMax
        --   currencyInfo.amount = currencyInfo.amount + 1
        --   currencyInfo.totalMax = currencyInfo.totalMax + 1
        --   if covenantID > 0 then
        --     ---@diagnostic disable-next-line: inject-field
        --     currencyInfo.covenant = currencyInfo.covenant or {}
        --     currencyInfo.covenant[covenantID] = currencyInfo.amount
        --   end
        -- elseif covenantID and (currencyID == 1810 or currencyID == 1813) then -- Redeemed Soul and Reservoir Anima
        --   if covenantID > 0 then
        --     ---@diagnostic disable-next-line: inject-field
        --     currencyInfo.covenant = currencyInfo.covenant or {}
        --     currencyInfo.covenant[covenantID] = currencyInfo.amount
        --   end
        -- elseif currencyID == 2800 then -- 10.2.6 Professions - Personal Tracker - S4 Spark Drops (Hidden)
        --   local duration = SI:GetNextWeeklyResetTime() - 1713276000 -- 2024-04-16T14:00:00+00:00
        --   currencyInfo.totalMax = floor(duration / 604800) -- 7 days
        -- elseif currencyID == 3010 then -- 10.2.6 Rewards - Personal Tracker - S4 Dinar Drops (Hidden)
        --   local duration = SI:GetNextWeeklyResetTime() - 1713880800 -- 2024-04-23T14:00:00+00:00
        --   currencyInfo.totalMax = floor(duration / 604800) -- 7 days
        end
        -- don't store useless info
        if currencyInfo.weeklyMax == 0 then currencyInfo.weeklyMax = nil end
        if currencyInfo.totalMax == 0 then currencyInfo.totalMax = nil end
        if currencyInfo.earnedThisWeek == 0 then currencyInfo.earnedThisWeek = nil end
        if currencyInfo.totalEarned == 0 then currencyInfo.totalEarned = nil end
        playerStore.currency[currencyID] = currencyInfo
      end
    end
  end
end

function Module:UpdateCurrencyItem()
  if not SI.db.Toons[SI.thisToon].currency then return end

  for currencyID, tbl in pairs(specialCurrencies) do
    if tbl.relatedItem and SI.db.Toons[SI.thisToon].currency[currencyID] then
      SI.db.Toons[SI.thisToon].currency[currencyID].relatedItemCount = GetItemCount(tbl.relatedItem.id)
    end
  end

  if SI.isClassicEra then
    for _, currencyID in ipairs(validCurrencies) do
      local currencyInfo = SI.db.Toons[SI.thisToon].currency[currencyID] or {}
      currencyInfo.amount = GetItemCount(currencyID)
      currencyInfo.relatedItemCount = GetItemCount(currencyID)
      SI.db.Toons[SI.thisToon].currency[currencyID] = currencyInfo
    end
  end
end
---@param sorted boolean? If `true`, returns currency list sorted by name
---@return number[]
function Module:GetCurrencyList(sorted)
  if sorted then return currencySorted end
  return validCurrencies
end

---@param currencyID integer
---@return string? categoryName display string for the currency's category
function Module:GetCurrencyCategory(currencyID)
  if not currencyID then return end
  return categoryByCurrencyID[currencyID]
end

---@param itemID integer?
---@return table<integer, {text: string, font: FontObject, color: {}}>?
function Module:ParseCurrencyItemTooltip(itemID)
  if not itemID then return end
  if not currencyTooltipCache[itemID] then
    currencyTooltipCache[itemID] = {}
  end
  SI.ScanTooltip:SetHyperlink(LinkUtil.FormatLink("item", " ", itemID))
  local tooltipInfo = currencyTooltipCache[itemID]
  for i = 1, SI.ScanTooltip:NumLines() do
    local line = _G["SavedInstancesScanTooltipTextLeft" .. i]
    tooltipInfo[i] = tooltipInfo[i] or {}
    tooltipInfo[i].text = line:GetText()
    tooltipInfo[i].font = line:GetFontObject()
    tooltipInfo[i].color = { line:GetTextColor() }
  end
  return tooltipInfo
end

---@return fun():integer?, {name: string, currencies: number[]}?
function Module:IterateCategories()
  local i = 0
  local categoryInfo = {}
  local currencyTable = Module.IsUsingCurrencyAPI and modernClassicCurrencies or classicEraCurrencies
  local orderedCategories = Module.IsUsingCurrencyAPI and orderedCategories or classicEraCategories
  return function()
    i = i + 1
    if i > #orderedCategories then
      return nil
    end
    local categoryName = orderedCategories[i];
    categoryInfo = {
      name = categoryName,
      currencies = currencyTable[categoryName],
    }
    return i, categoryInfo
  end
end

