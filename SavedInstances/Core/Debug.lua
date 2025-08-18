---@class SavedInstances
local SI, L = unpack((select(2, ...)))

-- Lua functions
local date, format, ipairs, strtrim, tinsert, time = date, format, ipairs, strtrim, tinsert, time

-- WoW API / Variables
local C_DateAndTime_GetCurrentCalendarTime = C_DateAndTime.GetCurrentCalendarTime
local C_QuestLog_GetAllCompletedQuestIDs = C_QuestLog.GetAllCompletedQuestIDs
local GetGameTime = GetGameTime
local GetQuestResetTime = GetQuestResetTime
local GetRealmName = GetRealmName
local GetRealZoneText = GetRealZoneText
local GetTime = GetTime
local UnitLevel = UnitLevel

local SecondsToTime = SecondsToTime

--- Adds a message to chat prefixed with the addon name.
---@param  str string
---@param ... any format arguments, if any, for the string 
function SI:Debug(str,...)
  if not SI or not SI.db or SI.db.Tooltip.DebugMode then
    SI:ChatMsg(str,...)
  end
end


function SI:TimeDebug()
  SI:ChatMsg("Version: %s", SI.version)
  SI:ChatMsg("Realm: %s (%s)", GetRealmName(), SI:GetRegion())
  SI:ChatMsg("Zone: %s (%s)", GetRealZoneText(), SI:GetCurrentMapAreaID())
  SI:ChatMsg("time() = %s, GetTime() = %s", time(), GetTime())
  SI:ChatMsg("Local time: %s local", tostring(date("%Y/%m/%d %H:%M:%S")))
  SI:ChatMsg("GetGameTime: %s:%s server", GetGameTime())

  local calender = C_DateAndTime_GetCurrentCalendarTime()
  SI:ChatMsg("C_DateAndTime.GetCurrentCalendarTime: %s/%s/%s server", calender.year, calender.month, calender.monthDay)
  SI:ChatMsg("GetQuestResetTime: %s", SecondsToTime(GetQuestResetTime()))
  SI:ChatMsg(
    date(
      "Daily reset: %Y/%m/%d %H:%M:%S local (based on GetQuestResetTime)", 
      time() + GetQuestResetTime()
    ) --[[@as string]]
  )

  local offset = SI:GetServerOffset()
  SI:ChatMsg("Local to server offset: %d hours", offset)
  offset = offset * 60 * 60 -- offset in seconds
  local time
  time = SI:GetNextDailyResetTime()
  SI:ChatMsg(
    "Next daily reset: %s local, %s server",
    tostring(date("%Y/%m/%d %H:%M:%S", time)), date("%Y/%m/%d %H:%M:%S", time + offset)
  )

  time = SI:GetNextWeeklyResetTime()
  SI:ChatMsg(
    "Next weekly reset: %s local, %s server",
    tostring(date("%Y/%m/%d %H:%M:%S", time)), date("%Y/%m/%d %H:%M:%S", time + offset)
  )

  time = SI:GetNextDailySkillResetTime()
  SI:ChatMsg(
    "Next skill reset: %s local, %s server",
    tostring(date("%Y/%m/%d %H:%M:%S", time)), date("%Y/%m/%d %H:%M:%S", time + offset)
  )

  time = SI:GetNextDarkmoonFaireEnd()
  SI:ChatMsg(
    "Next Darkmoon reset: %s local, %s server",
    tostring(date("%Y/%m/%d %H:%M:%S", time)), date("%Y/%m/%d %H:%M:%S", time + offset)
  )
end

do
  local function questTableToString(data)
    local level = UnitLevel('player')
    local ret = ''
    for index, questID in ipairs(data) do
      ret = ret .. format(
        "%s\124cffffff00\124Hquest:%s:%s\124h[%s]\124h\124r",
        (index == 1) and "" or ", ", questID, level, questID
      )
    end
    return ret
  end

  function SI:QuestDebug(info)
    local t = SI.db.Toons[SI.thisToon]
    local ql = C_QuestLog_GetAllCompletedQuestIDs()

    local cmd = info.input
    cmd = cmd and strtrim(cmd:gsub("^%s*(%w+)%s*","")):lower()
    if t.completedquests and (cmd == "load" or not SI.completedquests) then
      SI:ChatMsg("Loaded quest list")
      SI.completedquests = t.completedquests
    elseif cmd == "load" then
      SI:ChatMsg("No saved quest list")
    elseif cmd == "save" then
      SI:ChatMsg("Saved quest list")
      ---@diagnostic disable-next-line: inject-field
      t.completedquests = ql
    elseif cmd == "clear" then
      SI:ChatMsg("Cleared quest list")
      SI.completedquests = nil
      ---@diagnostic disable-next-line: inject-field
      t.completedquests = nil
      return
    elseif cmd and #cmd > 0 then
      SI:ChatMsg("Quest command not understood: '"..cmd.."'")
      SI:ChatMsg("/si quest ([save|load|clear])")
      return
    end
    local cnt = #ql
    local add = {}
    local remove = {}
    SI:ChatMsg("Completed quests: "..cnt)
    if SI.completedquests then
      local prev, curr = 1, 1
      while true do
        if not SI.completedquests[prev] then
          while ql[curr] do
            tinsert(add, ql[curr])
            curr = curr + 1
          end
          break
        elseif not ql[curr] then
          while SI.completedquests[prev] do
            tinsert(remove, SI.completedquests[prev])
            prev = prev + 1
          end
          break
        elseif SI.completedquests[prev] > ql[curr] then
          while ql[curr] and SI.completedquests[prev] > ql[curr] do
            tinsert(add, ql[curr])
            curr = curr + 1
          end
        elseif SI.completedquests[prev] < ql[curr] then
          while SI.completedquests[prev] and SI.completedquests[prev] < ql[curr] do
            tinsert(remove, SI.completedquests[prev])
            prev = prev + 1
          end
        else -- SI.completedquests[prev] == ql[curr]
          prev = prev + 1
          curr = curr + 1
        end
      end
      if #add > 0 then
        SI:ChatMsg("Added IDs:   " .. questTableToString(add))
      end
      if #remove > 0 then
        SI:ChatMsg("Removed IDs: " .. questTableToString(remove))
      end
    end
    SI.completedquests = ql
  end
end
