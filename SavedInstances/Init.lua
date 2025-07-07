local
---@type string
addon,
---@type {[1]: SavedInstances, [2]: table<string, string>}
Engine = ...

---@class SavedInstances : AceAddon, AceEvent-3.0, AceBucket-3.0, AceTimer-3.0
local SI = LibStub('AceAddon-3.0'):NewAddon(addon, 'AceEvent-3.0', 'AceTimer-3.0', 'AceBucket-3.0')


Engine[1] = SI
Engine[2] = {} -- locale table.
_G.SavedInstances = Engine

SI.Libs = {}
---@class QTip : LibQTip-1.0
---@field Acquire fun(self: QTip, name: string, columns: number, ...): QTip
SI.Libs.QTip = LibStub('LibQTip-1.0')
SI.Libs.LDB = LibStub('LibDataBroker-1.1', true)
SI.Libs.LDBI = SI.Libs.LDB and LibStub('LibDBIcon-1.0', true)

-- In classic some popular addons add stuff into the "GameTooltipTemplate" which we might accidentally scan so we use "SharedTooltipTemplate".
-- However, "SharedTooltipTemplate" doesn't have SetHyperlink method in retail
local tooltipTemplate = SI.isRetail and 'GameTooltipTemplate' or 'SharedTooltipTemplate, GameTooltipTemplate'
---@class SavedInstances.ScanTooltip : GameTooltip
SI.ScanTooltip = CreateFrame('GameTooltip', 'SavedInstancesScanTooltip', nil, tooltipTemplate)
local setHyperlink = SI.ScanTooltip.SetHyperlink

assert(setHyperlink, 'Failed to create ScanTooltip, missing `SetHyperlink` method on inherited tooltip')
---@param link string?
function SI.ScanTooltip:SetHyperlink(link)
    if not link then return end
    self:SetOwner(WorldFrame, 'ANCHOR_NONE')
    -- self:ClearAllPoints()
	-- self:SetPoint("BOTTOMLEFT", WorldFrame, "BOTTOMLEFT", 0, 0);
    setHyperlink(self, link)
    -- self:Show()
end
SI.ScanTooltip:SetOwner(WorldFrame, 'ANCHOR_NONE')


SI.playerName = UnitName('player')
SI.playerLevel = UnitLevel('player')
SI.realmName = GetRealmName()
SI.thisToon = SI.playerName .. ' - ' .. SI.realmName
SI.maxLevel = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion() or GetEffectivePlayerMaxLevel()
SI.locale = GetLocale()

local build = floor(select(4, GetBuildInfo()) / 10000)
---@enum ExpansionID
local Expansion = {
    Classic = 0,
    TBC = 1,
    Wrath = 2,
    Cata = 3,
    Mists = 4,
    Mainline = 5, -- Retail
}
local ExpansionProjectID = {
    [Expansion.Classic] = WOW_PROJECT_CLASSIC,
    [Expansion.TBC] = WOW_PROJECT_BURNING_CRUSADE_CLASSIC,
    [Expansion.Wrath] = WOW_PROJECT_WRATH_CLASSIC,
    [Expansion.Cata] = WOW_PROJECT_CATACLYSM_CLASSIC,
    [Expansion.Mists] = WOW_PROJECT_MISTS_CLASSIC or 19,
    [Expansion.Mainline] = WOW_PROJECT_MAINLINE,
}
local WoWProjectExpansionID = tInvert(ExpansionProjectID)
Expansion.Current = WoWProjectExpansionID[WOW_PROJECT_ID]

SI.Enum = {}
SI.Enum.Expansion = Expansion

SI.isRetail = Expansion.Current == Expansion.Mainline
SI.isClassicEra = Expansion.Current == Expansion.Classic
SI.isWrath = Expansion.Current == Expansion.Wrath
SI.isCataclysm = Expansion.Current == Expansion.Cata
SI.isSoD = SI.isClassicEra
    and C_Seasons.HasActiveSeason()
    and C_Seasons.GetActiveSeason() == Enum.SeasonID.SeasonOfDiscovery;

SI.questCheckMark = '\124A:UI-LFG-ReadyMark:14:14\124a'
SI.questTurnin = '\124A:QuestTurnin:14:14\124a'
SI.questNormal = '\124A:QuestNormal:14:14\124a'
