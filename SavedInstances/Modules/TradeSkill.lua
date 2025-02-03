---@type SavedInstances
local SI, L = unpack((select(2, ...)))
---@class TradeSkillModule : AceModule , AceEvent-3.0, AceTimer-3.0, AceBucket-3.0
---@field castTimestamp number? # Unix server timestamp the last detected cast for a tracked trade skill
---@field lastSpellID number? # the spellID of the last detected cast for a tracked trade skill
---@field missingWarned table<number, boolean> # [spellID]: `true` if a warning was already issued for the spellID
---@field cooldownFound table<number, boolean> # [spellID]: `true` if a cooldown was found for the spellID during the player scan
local Module = SI:NewModule('TradeSkill', 'AceEvent-3.0', 'AceTimer-3.0', 'AceBucket-3.0')

-- Lua functions
local pairs, type, floor, abs, format = pairs, type, floor, abs, format
local date, ipairs, tonumber, time = date, ipairs, tonumber, time
local _G = _G

-- WoW API / Variables
local C_TradeSkillUI_GetAllRecipeIDs = C_TradeSkillUI.GetAllRecipeIDs
local C_TradeSkillUI_GetFilteredRecipeIDs = C_TradeSkillUI.GetFilteredRecipeIDs
local C_TradeSkillUI_GetRecipeCooldown = C_TradeSkillUI.GetRecipeCooldown
local C_TradeSkillUI_IsTradeSkillGuild = C_TradeSkillUI.IsTradeSkillGuild
local C_TradeSkillUI_IsTradeSkillLinked = C_TradeSkillUI.IsTradeSkillLinked
local C_TradeSkillUI_GetRecipeInfo = C_TradeSkillUI.GetRecipeInfo

-- Helper for correcting C_Container.GetItemCooldown AFTER a system reboot
-- src: https://github.com/Stanzilla/WoWUIBugs/issues/47#issuecomment-710698976
---@param lastCast number system time when spell was last cast.
local function getCastTimestamp(lastCast)
  local systemTime = GetTime()
  -- note: `lastCast` times for spells put on cooldown BEFORE a system restart will-
  -- be greater than the current value of `GetTime()`.
  if lastCast < systemTime then
    return SI:SystemTimeToUnix(lastCast)
  end
  local startupTime = time() - systemTime
  -- To find the time of the lastCast based on the _current_ system time, subtract an epoch duration.
  -- (We are assuming `GetTime` is based off a 32bit sized ms counter).
  local currLastCast = lastCast - ((2 ^ 32) / 1000)
  local castTimestamp = startupTime - ((2 ^ 32) / 1000 - lastCast)
  assert(castTimestamp == SI:SystemTimeToUnix(currLastCast), "failed to match time fixes", castTimestamp, SI:SystemTimeToUnix(currLastCast))
  return SI:SystemTimeToUnix(currLastCast)
end

if SI.isClassicEra then -- Era Compatibility
  assert(not C_TradeSkillUI_GetRecipeInfo,
    "C_TradeSkillUI is now supported in Classic! Open an issue on github to request support."
  );
  ---@type fun(): isLinked: boolean?, linkSource: string?
  C_TradeSkillUI_IsTradeSkillLinked = IsTradeSkillLinked
  C_TradeSkillUI_IsTradeSkillGuild = function() return false end
  ---@return number[]
  C_TradeSkillUI_GetAllRecipeIDs = function()
    local ids = {}
    for i = 1, GetNumTradeSkills() do
      ids[i] = i
    end
    return ids 
  end
  C_TradeSkillUI_GetFilteredRecipeIDs = C_TradeSkillUI_GetAllRecipeIDs
  ---@type fun(index: number): remainingSeconds: number
  C_TradeSkillUI_GetRecipeCooldown = GetTradeSkillCooldown
  ---@type fun(index: number): skillName: string?
  C_TradeSkillUI_GetRecipeInfo = GetTradeSkillInfo
end
local GetItemCooldown = GetItemCooldown 
  or C_Container.GetItemCooldown -- former function not in the wotlk client
local GetItemInfo = GetItemInfo
local GetSpellInfo = GetSpellInfo
local GetSpellLink = GetSpellLink

---@type table<number, string|boolean|number> [spellID]: displayStrKey?
local trackedTradeCrafts = {
  -- Alchemy
  -- Vanilla
  [25146] = "xmute", -- Transmute: Elemental Fire
  [17187] = "xmute", -- Transmute: Arcanite
  [11479] = "xmute", -- Transmute: Iron to Gold
  [11480] = "xmute", -- Transmute: Mithril to Truesilver
  [17559] = "xmute", -- Transmute: Air to Fire
  [17566] = "xmute", -- Transmute: Earth to Life
  [17561] = "xmute", -- Transmute: Earth to Water
  [17560] = "xmute", -- Transmute: Fire to Earth
  [17565] = "xmute", -- Transmute: Life to Earth
  [17563] = "xmute", -- Transmute: Undeath to Water
  [17562] = "xmute", -- Transmute: Water to Air
  [17564] = "xmute", -- Transmute: Water to Undeath

  -- BC
  [28566] = "xmute", -- Transmute: Primal Air to Fire
  [28585] = "xmute", -- Transmute: Primal Earth to Life
  [28567] = "xmute", -- Transmute: Primal Earth to Water
  [28568] = "xmute", -- Transmute: Primal Fire to Earth
  [28583] = "xmute", -- Transmute: Primal Fire to Mana
  [28584] = "xmute", -- Transmute: Primal Life to Earth
  [28582] = "xmute", -- Transmute: Primal Mana to Fire
  [28580] = "xmute", -- Transmute: Primal Shadow to Water
  [28569] = "xmute", -- Transmute: Primal Water to Air
  [28581] = "xmute", -- Transmute: Primal Water to Shadow

  -- WotLK
  [60893] = 3,       -- Northrend Alchemy Research: 3 days
  [53777] = "xmute", -- Transmute: Eternal Air to Earth
  [53776] = "xmute", -- Transmute: Eternal Air to Water
  [53781] = "xmute", -- Transmute: Eternal Earth to Air
  [53782] = "xmute", -- Transmute: Eternal Earth to Shadow
  [53775] = "xmute", -- Transmute: Eternal Fire to Life
  [53774] = "xmute", -- Transmute: Eternal Fire to Water
  [53773] = "xmute", -- Transmute: Eternal Life to Fire
  [53771] = "xmute", -- Transmute: Eternal Life to Shadow
  [54020] = "xmute", -- Transmute: Eternal Might
  [53779] = "xmute", -- Transmute: Eternal Shadow to Earth
  [53780] = "xmute", -- Transmute: Eternal Shadow to Life
  [53783] = "xmute", -- Transmute: Eternal Water to Air
  [53784] = "xmute", -- Transmute: Eternal Water to Fire
  [66658] = "xmute", -- Transmute: Ametrine
  [66659] = "xmute", -- Transmute: Cardinal Ruby
  [66660] = "xmute", -- Transmute: King's Amber
  [66662] = "xmute", -- Transmute: Dreadstone
  [66663] = "xmute", -- Transmute: Majestic Zircon
  [66664] = "xmute", -- Transmute: Eye of Zul

  -- Cata
  [78866] = "xmute", -- Transmute: Living Elements
  [80244] = "xmute", -- Transmute: Pyrium Bar

  -- MoP
  [114780] = "xmute", -- Transmute: Living Steel

  -- WoD
  [175880] = true,    -- Secrets of Draenor
  [156587] = true,    -- Alchemical Catalyst (4)
  [168042] = true,    -- Alchemical Catalyst (10), 3 charges w/ 24hr recharge
  [181643] = "xmute", -- Transmute: Savage Blood

  -- Legion
  [188800] = "wildxmute",   -- Transmute: Wild Transmutation (Rank 1)
  [188801] = "wildxmute",   -- Transmute: Wild Transmutation (Rank 2)
  [188802] = "wildxmute",   -- Transmute: Wild Transmutation (Rank 3)
  [213248] = "legionxmute", -- Transmute: Ore to Cloth
  [213249] = "legionxmute", -- Transmute: Cloth to Skins
  [213250] = "legionxmute", -- Transmute: Skins to Ore
  [213251] = "legionxmute", -- Transmute: Ore to Herbs
  [213252] = "legionxmute", -- Transmute: Cloth to Herbs
  [213253] = "legionxmute", -- Transmute: Skins to Herbs
  [213254] = "legionxmute", -- Transmute: Fish to Gems
  [213255] = "legionxmute", -- Transmute: Meat to Pants
  [213256] = "legionxmute", -- Transmute: Meat to Pet
  [213257] = "legionxmute", -- Transmute: Blood of Sargeras
  [247701] = "legionxmute", -- Transmute: Primal Sargerite

  -- BfA
  [251832] = "xmute", -- Transmute: Expulsom
  [251314] = "xmute", -- Transmute: Cloth to Skins
  [251822] = "xmute", -- Transmute: Fish to Gems
  [251306] = "xmute", -- Transmute: Herbs to Cloth
  [251305] = "xmute", -- Transmute: Herbs to Ore
  [251808] = "xmute", -- Transmute: Meat to Pet
  [251310] = "xmute", -- Transmute: Ore to Cloth
  [251311] = "xmute", -- Transmute: Ore to Gems
  [251309] = "xmute", -- Transmute: Ore to Herbs
  [286547] = "xmute", -- Transmute: Herbs to Anchors

  -- SL
  [307142] = true, -- Shadowghast Ingot
  [307143] = true, -- Shadestone
  [307144] = true, -- Stones to Ore

  -- Dragonflight
  [370707] = "dragonflightxmute", -- Transmute: Awakened Fire
  [370708] = "dragonflightxmute", -- Transmute: Awakened Frost
  [370710] = "dragonflightxmute", -- Transmute: Awakened Earth
  [370711] = "dragonflightxmute", -- Transmute: Awakened Air
  [370714] = "dragonflightxmute", -- Transmute: Decay to Elements
  [370715] = "dragonflightxmute", -- Transmute: Order to Elements
  [405847] = "dragonflightxmute", -- Transmute: Dracothyst
  [370743] = "dragonflightexper", -- Basic Potion Experimentation
  [370745] = "dragonflightexper", -- Advanced Potion Experimentation
  [370746] = "dragonflightexper", -- Basic Phial Experimentation
  [370747] = "dragonflightexper", -- Advanced Phial Experimentation

  -- Enchanting
  [18560] = true, -- Mooncloth
  [28027]  = "sphere", -- Prismatic Sphere (2-day shared, 5.2.0 verified)
  [28028]  = "sphere", -- Void Sphere (2-day shared, 5.2.0 verified)
  [116499] = true,     -- Sha Crystal
  [177043] = true,     -- Secrets of Draenor
  [169092] = true,     -- Temporal Crystal

  -- Jewelcrafting
  [47280]  = true,    -- Brilliant Glass, still has a cd (5.2.0 verified)
  [73478]  = true,    -- Fire Prism, still has a cd (5.2.0 verified)
  [131691] = "facet", -- Imperial Amethyst/Facets of Research
  [131686] = "facet", -- Primordial Ruby/Facets of Research
  [131593] = "facet", -- River's Heart/Facets of Research
  [131695] = "facet", -- Sun's Radiance/Facets of Research
  [131690] = "facet", -- Vermilion Onyx/Facets of Research
  [131688] = "facet", -- Wild Jade/Facets of Research
  [140050] = true,    -- Serpent's Heart
  [176087] = true,    -- Secrets of Draenor
  [170700] = true,    -- Taladite Crystal
  [374546] = true,    -- Queen's Gift
  [374547] = true,    -- Dreamer's Vision
  [374548] = true,    -- Keeper's Glory
  [374549] = true,    -- Earthwarden's Prize
  [374550] = true,    -- Timewatcher's Patience
  [374551] = true,    -- Jeweled Dragon's Heart

  -- Tailoring
  [75141] = 7,     -- Dream of Skywall
  [75145] = 7,     -- Dream of Ragnaros
  [75144] = 7,     -- Dream of Hyjal
  [75142] = 7,     -- Dream of Deepholm
  [75146] = 7,     -- Dream of Azshara
  [143011] = true, -- Celestial Cloth
  [125557] = true, -- Imperial Silk
  [56005]  = 7,    -- Glacial Bag (5.2.0 verified)
  [176058] = true, -- Secrets of Draenor
  [168835] = true, -- Hexweave Cloth
  [376556] = true, -- Azureweave Bolt
  [376557] = true, -- Chronocloth Bolt

  -- Inscription
  [61288]  = true, -- Minor Inscription Research
  [61177]  = true, -- Northrend Inscription Research
  [86654]  = true, -- Horde Forged Documents
  [89244]  = true, -- Alliance Forged Documents
  [112996] = true, -- Scroll of Wisdom
  [169081] = true, -- War Paints
  [177045] = true, -- Secrets of Draenor
  [176513] = true, -- Draenor Merchant Order

  -- Blacksmithing
  [138646] = true, -- Lightning Steel Ingot
  [143255] = true, -- Balanced Trillium Ingot
  [171690] = true, -- Truesteel Ingot
  [171718] = true, -- Truestell Ingot, 3 charges w/ 24hr recharge
  [176090] = true, -- Secrets of Draenor

  -- Leatherworking
  [140040] = "magni", -- Magnificence of Leather
  [140041] = "magni", -- Magnificence of Scales
  [142976] = true,    -- Hardened Magnificent Hide
  [171391] = true,    -- Burnished Leather
  [176089] = true,    -- Secrets of Draenor
  [19566] = "item", -- Salt Shaker (item)

  -- Engineering
  [139176] = true, -- Stabilized Lightning Source
  [169080] = true, -- Gearspring Parts
  [177054] = true, -- Secrets of Draenor
  [382358] = true, -- Suspiciously Silent Crate
  [382354] = true, -- Suspiciously Ticking Crate

  -- Cooking
  [378302] = true, -- Ooey-Gooey Chocolate

  -- Item
  [54710]  = "item", -- MOLL-E
  [67826]  = "item", -- Jeeves
  [126459] = "item", -- Blingtron 4000
  [161414] = "item", -- Blingtron 5000
  [200061] = "item", -- Rechargeable Reaves Battery
  [261602] = "item", -- Katy's Stampwhistle
  [298926] = "item", -- Blingtron 7000
  -- Wormhole
  [67833]  = "item", -- Wormhole Generator: Northrend
  [126755] = "item", -- Wormhole Generator: Pandaria
  [163830] = "item", -- Wormhole Centrifuge (Draenor)
  [250796] = "item", -- Wormhole Generator: Argus
  [299083] = "item", -- Wormhole Generator: Kul Tiras
  [299084] = "item", -- Wormhole Generator: Zandalar
  [324031] = "item", -- Wormhole Generator: Shadowlands
  [386379] = "item", -- Wyrmhole Generator
  -- Transporter
  [23453]  = "item", -- Ultrasafe Transporter: Gadgetzhan
  [36941]  = "item", -- Ultrasafe Transporter: Toshley's Station
}
---@type table<number, number> [spellID]: itemID
local trackedItemCrafts = {
  -- Vanilla
  [13399] = 11020 , -- Evergreen Pouch (10m cd)
  [19566] = 15846, -- Salt Shaker

  [54710]  = 40768,  -- MOLL-E
  [67826]  = 49040,  -- Jeeves
  [126459] = 87214,  -- Blingtron 4000
  [161414] = 111821, -- Blingtron 5000
  [200061] = 144341, -- Rechargeable Reaves Battery
  [261602] = 156833, -- Katy's Stampwhistle
  [298926] = 168667, -- Blingtron 7000
  -- Wormhole
  [67833]  = 48933,  -- Wormhole Generator: Northrend
  [126755] = 87215,  -- Wormhole Generator: Pandaria
  [163830] = 112059, -- Wormhole Centrifuge (Draenor)
  [250796] = 151652, -- Wormhole Generator: Argus
  [299083] = 168807, -- Wormhole Generator: Kul Tiras
  [299084] = 168808, -- Wormhole Generator: Zandalar
  [324031] = 172924, -- Wormhole Generator: Shadowlands
  [386379] = 198156, -- Wyrmhole Generator
  -- Transporter
  [23453]  = 18986,  -- Ultrasafe Transporter: Gadgetzhan
  [36941]  = 30544,  -- Ultrasafe Transporter: Toshley's Station
}
--- TODO: i think all this data should be in 1 list, since we already have the spellId's


local categoryNames = {
  ["xmute"] = GetSpellInfo(2259).. ": "..L["Transmute"],
  -- Legion Transmutes
  ["wildxmute"] = SI.isRetail and (GetSpellInfo(2259).. ": "..L["Wild Transmute"]),
  ["legionxmute"] = SI.isRetail and (GetSpellInfo(2259).. ": "..L["Legion Transmute"]),
  -- Dragonflight Transmutes
  ["dragonflightxmute"] = SI.isRetail and (GetSpellInfo(2259).. ": "..L["Dragonflight Transmute"]),
  ["dragonflightexper"] = SI.isRetail and (GetSpellInfo(2259).. ": "..L["Dragonflight Experimentation"]),
  -- Pandaria Jewelcrafting
  ["facet"] =  SI.isRetail and (GetSpellInfo(25229) ..": "..L["Facets of Research"]),
  -- Wotlk Enchanting
  ["sphere"] = not SI.isClassicEra and (GetSpellInfo(7411).. ": "..GetSpellInfo(28027)),
  -- Pandaria Leatherworking 
  ["magni"] = SI.isRetail and (GetSpellInfo(25229) ..": "..GetSpellInfo(140040)),
}

---@param itemID number
---@return integer?
---@return integer?
---@return ContainerItemInfo?
local searchBagForItem = function(itemID)
  for bag = 0, 4 do
      for slot = 1, C_Container.GetContainerNumSlots(bag) do
          local info = C_Container.GetContainerItemInfo(bag, slot)
          if info
              and info.itemID == itemID
          then
              return bag, slot, info
          end
      end
  end
end

---Returns the cooldown of a spell or item associated with a trade skill.
---@param spellID number # spellID of the trade skill or the item (`GetItemSpell(spellID)` to find)
---@return number? # `nil` for no cooldown, otherwise the cooldown in seconds
local function getTradeSkillCooldown(spellID)
  -- check if the spell is associated with an item
  local itemID = trackedItemCrafts[spellID] or (trackedTradeCrafts[spellID] == "item" and spellID)
  if itemID then
      ---  itemInfo is just returned for debug purposes. consider removing it and the call to `GetContainerItemInfo`
      local bagId, slotId, itemInfo = searchBagForItem(itemID)
      if bagId and slotId and itemInfo then
        local _, duration, _ = C_Container.GetContainerItemCooldown(bagId, slotId)
        SI:Debug("Tradeskill associated item %s found in bags | cooldown: %s", itemInfo.hyperlink, SecondsToTime(duration))
        if duration > 0 then
          return duration
        end
      end
  else -- not from item
    local _, duration = GetSpellCooldown(spellID)
    -- this might not be necessary, just a backup.
    if duration < 1 then
      duration = (GetSpellBaseCooldown(spellID) or 0) / 1000
    end
      local link = GetSpellLink(spellID) -- see comment on itemInfo above
      SI:Debug("Tradeskill %s recently cast | cooldown: %s", link, SecondsToTime(duration))
    if duration > 0 then
        return duration
    end
  end
end

function Module:OnEnable()
  self:RegisterBucketEvent("TRADE_SKILL_LIST_UPDATE", 1)
  self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
  self.missingWarned = {}
  self.cooldownFound = {}
end

function Module:TRADE_SKILL_LIST_UPDATE()
  self:ScanPlayerTradeSkills()
end

function Module:UNIT_SPELLCAST_SUCCEEDED(_, unit, _, spellID)
  if unit == "player" 
  and (trackedTradeCrafts[spellID] or trackedItemCrafts[spellID])
  then
    self.castTimestamp = time()
    self.lastSpellID = spellID
    self:RegisterEvent("SPELL_UPDATE_COOLDOWN")

  end
end

-- This event fires shortly after SPELL_CAST_ events
-- client is not updated with new cooldown info until after this event
-- see https://wowpedia.fandom.com/wiki/SPELL_UPDATE_COOLDOWN
function Module:SPELL_UPDATE_COOLDOWN()
  if not self.lastSpellID then return end
  local isOK = self:TryRecordTradeSkill(self.lastSpellID)
  if isOK then
    self:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
    self.lastSpellID = nil
  else
    -- debounce 0.5s incase the cooldown is still not available to client. 
    self:ScheduleTimer(function() self:TryScanPlayerSkill(self.lastSpellID) end, 0.5)    
  end
end

---Attempts to add a recent cast to the currents player tracked tradesksill store.
---If the CD is recognized and successfully added, returns true.
---The `cooldown` param is here for `ScanPlayerTradeSkills` and how it deals with daily cooldowns.
---not sure if its correct but keeping it incase it breaks something. 
---@param spellID number
---@param lastCast number? # if known, pass to override the value set by the last CAST event
---@param cooldown number? # if known, pass to override any cooldown that would be found 
---@return boolean?
function Module:TryRecordTradeSkill(spellID, lastCast, cooldown)
  if not spellID then return end
  local castTimestamp = lastCast or self.castTimestamp
  if not castTimestamp then
    SI:Debug("No `lastCast` time found for trade skill %s", GetSpellLink(spellID) or spellID)
    return 
  end
  local spellName = GetSpellInfo(spellID)
  local displayStr = trackedTradeCrafts[spellID]
  local isItem = trackedItemCrafts[spellID] or displayStr == "item"
  
  ---@type string|number # used to index the Toon.Skills table
  local skillKey = spellID 
  local playerStore = SI.db.Toons[SI.thisToon]
  playerStore.Skills = playerStore.Skills or {}

  local recordSkill = function(title, link, expiration)
    local skillStore = playerStore.Skills[skillKey] or {}
    skillStore.Title = title
    skillStore.Link = link
    skillStore.Expires = expiration
    skillStore.lastCast = self.castTimestamp
    playerStore.Skills[skillKey] = skillStore
  end

  local tooltipTitle = spellName
  local hyperlink = nil
  local expiry = nil
  local cooldown = cooldown or getTradeSkillCooldown(spellID)
  if cooldown and cooldown > 2 then -- might be global cooldowns, #509
    expiry = castTimestamp + cooldown
  end

  if not expiry then
    if type(displayStr) == "number" then
      -- i think its better not to just assume a 1day cooldown if no information was found.
      -- better to hardcode durration for any exceptions 
      expiry = SI:GetNextDailySkillResetTime()
      if not expiry then return end -- ticket 127
      -- over a day, make a rough guess
      expiry = expiry + (displayStr - 1) * 24 * 60 * 60
      SI:Debug("Tradskill %s is using hardcoded cooldown of %i days", GetSpellLink(spellID) or spellID)
      recordSkill(tooltipTitle, hyperlink, expiry)
      return true
    end
    SI:Debug("Tradeskill %s has no cooldown but is being tracked", GetSpellLink(spellID) or spellID)
    return 
    -- maybe nil it from the list?
  end
  if not displayStr and not trackedItemCrafts[spellID] then
    if not self.missingWarned[spellID] then
      self.missingWarned[spellID] = true
      SI:BugReport("Unrecognized trade skill cd "..(GetSpellInfo(spellID) or "??").." ("..spellID..")")
    end
  end
  -- use item name as some item spellnames are ambiguous or wrong
  if isItem then
    tooltipTitle, hyperlink = GetItemInfo(trackedItemCrafts[spellID])
    tooltipTitle = tooltipTitle or spellName
  end

  -- use the hardcoded displayStr if available
  if type(displayStr) == "string" then
    skillKey = displayStr
    tooltipTitle = categoryNames[displayStr] or tooltipTitle
  end

  -- tt scan for the full name with profession
  -- (i dont like this. part of original code)
  -- in classic there are no spell links (yet)
  local spellLink = GetSpellLink(spellID)
  if spellLink and #spellLink > 0 and not SI.isClassicEra then 
    hyperlink = "\124cffffd000\124Henchant:" .. spellID .. "\124h[X]\124h\124r"
    -- GameTooltip_SetBasicTooltip(SI.ScanTooltip, " ")
    SI.ScanTooltip:SetHyperlink(spellLink)
    SI.ScanTooltip:Show()
    local line = _G[SI.ScanTooltip:GetName() .. "TextLeft1"]
    line = line and line:GetText()
    if line and #line > 0 then
      tooltipTitle = line
      hyperlink = hyperlink:gsub("X", line)
    else
      hyperlink = nil
    end
  end
  SI.ScanTooltip:Hide()
  recordSkill(tooltipTitle, hyperlink, expiry)
  return true
end

--- will call `ScanPlayerTradeSkills` with `isAll` true if the first scan returns 0 spells on CD
---@param spellID number
function Module:TryScanPlayerSkill(spellID)
  local count = self:ScanPlayerTradeSkills()
  if count == 0 or not self.cooldownFound[spellID] then
    -- scan failed, probably because the skill is hidden - try again
    -- why not just force use all recpies the first time around?
    local rescanCount = self:ScanPlayerTradeSkills(true)
    SI:Debug("Rescan: " .. (rescanCount == count and "Failed" or "Success"))
  end
end

---@param isAll boolean?
function Module:ScanPlayerTradeSkills(isAll)
  if C_TradeSkillUI_IsTradeSkillLinked() or C_TradeSkillUI_IsTradeSkillGuild() then return end

  local count = 0
  local playerRecipies = isAll and C_TradeSkillUI_GetAllRecipeIDs() or C_TradeSkillUI_GetFilteredRecipeIDs()
  for _, recipieID in ipairs(playerRecipies or {}) do
    --- note: in classic and wrath recipieID is simply an index for the craft number in whatever proffession the players last opened/used
    local remainingCD, isDayCooldown = C_TradeSkillUI_GetRecipeCooldown(recipieID)
    if isDayCooldown == nil then
      local msCooldown = GetSpellBaseCooldown(recipieID)
      if msCooldown then
        local days = msCooldown / (1000 * 60 * 60 * 24)
        isDayCooldown = days >= 1
      end
    end
    if remainingCD  and remainingCD > 0 then
      SI:Debug(
        "Skill CD found. %s cast %s. cooldown: %s",
        C_TradeSkillUI_GetRecipeInfo(recipieID), recipieID, SecondsToTime(remainingCD or 0)
      )
    end
    local expiry
    if remainingCD and isDayCooldown -- GetRecipeCooldown often returns WRONG answers for daily cds
    and not tonumber(trackedTradeCrafts[recipieID]) -- daily flag incorrectly set for some multi-day cds (Northrend Alchemy Research)
    then
      expiry = SI:GetNextDailySkillResetTime()
    elseif remainingCD and remainingCD > 0 then
      expiry = time() + remainingCD -- on cooldown
    end
    -- ignore any off cooldown or no cooldown
    if expiry then       
      self.cooldownFound = self.cooldownFound or {}
      self.cooldownFound[recipieID] = true
      count = count + 1
      
      local lastCast = time() - remainingCD
      local totalCD = expiry - lastCast
      self:TryRecordTradeSkill(recipieID, lastCast, totalCD)
    end
  end
  return count
end

function Module:ScanPlayerItemCooldowns()
  -- alternatively we could search bags for any item on cooldown and use GetItemSpell to find the spellID
  -- then we could use the spellID to find the trackedTradeCrafts entry, some items dont have an associated profession tho.
  -- might rework this logic in the future
  for spellID, itemID in pairs(trackedItemCrafts) do
    local start, duration = GetItemCooldown(itemID)
    if start and duration and start > 0 then
      self:TryRecordTradeSkill(spellID, getCastTimestamp(start), duration)
    end
  end
end
function Module:ScanItemCDs() Module:ScanPlayerItemCooldowns() end  -- Support the old API name

-- local saved = {
--   ---@class cooldownInfo 
--   ---@field expirationTime number?
--   ---@field lastCast number Unix timestamp in seconds when last cast 
--   ---@field duration number?
--   ---@field icon string|number?
--   ---@field name string?
--   ---@field owner string?
--   ---@field spellID string?
--   ---@field itemID string?
--   ---@field fromItem boolean?

--   ---@type table<string, table<number, cooldownInfo>>
--   cooldownsByCharacter = {
--       -- [characterName] = {
--       --     [spellID]: cooldownInfo
--       -- },
--   }
-- }

