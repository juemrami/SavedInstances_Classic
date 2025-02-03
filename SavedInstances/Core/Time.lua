---@class SavedInstances
local SI, L = unpack((select(2, ...)))

-- Lua functions
local date, floor, time, tonumber = date, floor, time, tonumber

-- WoW API / Variables
local C_DateAndTime_GetCurrentCalendarTime = C_DateAndTime.GetCurrentCalendarTime
local C_DateAndTime_GetSecondsUntilWeeklyReset = C_DateAndTime.GetSecondsUntilWeeklyReset
local C_DateAndTime_GetSecondsUntilDailyReset = C_DateAndTime.GetSecondsUntilDailyReset
local C_Calendar_GetMonthInfo = C_Calendar.GetMonthInfo
local C_Calendar_SetAbsMonth = C_Calendar.SetAbsMonth
local GetQuestResetTime = GetQuestResetTime

-- Current unix time minus the users system uptime (seconds).
local systemStartTimestamp = time() - GetTime();

--- Converts from a system time values like `GetTime` to a unix timestamp values like `time`.
---@param systemTime number?
---@return number? timestamp
function SI:SystemTimeToUnix(systemTime)
  if not systemTime then return end
  return systemStartTimestamp + systemTime
end

--- returns how many __hours__ the server time is ahead of local time.
--- To convert local time -> server time: add this value
--- To convert server time -> local time: subtract this value
---@return number offset
function SI:GetServerOffset()
  local serverDate = C_DateAndTime_GetCurrentCalendarTime() -- 1-based starts on Sun
  local serverWeekday, serverMinute, serverHour = serverDate.weekday - 1, serverDate.minute, serverDate.hour
  -- #211: date('%w') is 0-based starts on Sun
  local localWeekday = tonumber(date('%w'))
  local localHour, localMinute = tonumber(date('%H')), tonumber(date('%M'))
  if serverWeekday == (localWeekday + 1) % 7 then -- server is a day ahead
    serverHour = serverHour + 24
  elseif localWeekday == (serverWeekday + 1) % 7 then -- local is a day ahead
    localHour = localHour + 24
  end
  local serverT = serverHour + serverMinute / 60
  local localT = localHour + localMinute / 60
  local offset = floor((serverT - localT) * 2 + 0.5) / 2
  return offset
end

--- Returns unix timestamp in seconds of the next daily reset time.
---@return number? resetTimestamp nil if the reset time cannot be determined.
function SI:GetNextDailyResetTime()
  local resetTime = GetQuestResetTime()
  resetTime = resetTime or C_DateAndTime_GetSecondsUntilDailyReset() -- try C API

  if not resetTime -- ticket 43: `GetQuestResetTime()` can fail during startup
    or resetTime <= 0 -- also right after a daylight savings rollover, when it returns negative values >.<
    or resetTime > 24 * 60 * 60 + 30 -- can also be wrong near reset in an instance
  then
    return 
  end

  return time() + resetTime
end

SI.GetNextDailySkillResetTime = SI.GetNextDailyResetTime

--- Returns unix timestamp in seconds for the next weekly reset.
---@return number resetTimestamp
function SI:GetNextWeeklyResetTime()
  return time() + C_DateAndTime_GetSecondsUntilWeeklyReset()
end

---@return number timestamp time in seconds remaining until the ending of the current or upcoming dmf.
function SI:GetNextDarkmoonResetTime()
    local DARKMOON_EVENT_ID = 479
    local current = C_DateAndTime_GetCurrentCalendarTime()
    C_Calendar_SetAbsMonth(current.month, current.year)
    local currentMonth = C_Calendar_GetMonthInfo()
    local getNextEndTimeTable = function(getUpcoming)
        local startDay = current.monthDay
        local stopDay = getUpcoming and currentMonth.numDays or startDay
        for day = startDay, stopDay do
            for event = 1, C_Calendar.GetNumDayEvents(0, day) do
                local dayEvent = C_Calendar.GetDayEvent(0, day, event)
                if dayEvent.eventID == DARKMOON_EVENT_ID then
                    return {
                        year = dayEvent.endTime.year,
                        day = dayEvent.endTime.monthDay,
                        month = dayEvent.endTime.month,
                        hour = dayEvent.endTime.hour,
                        min = dayEvent.endTime.minute,
                    }
                end
            end
        end
        -- previous method as backup | todo: improve DMF detection for Era/SoD.
        -- Darkmoon faire runs from first Sunday of each month to following Saturday
        local firstWeekday = currentMonth.firstWeekday
        local firstSunday = ((firstWeekday == 1) and 1) or (9 - firstWeekday)
        return {
            year = currentMonth.year,
            day = firstSunday + 7, -- 1 days of "slop"
            month = currentMonth.month,
            hour = 23,
            min = 59,
        }
    end
    local darkmoonEnd = getNextEndTimeTable(true)
    -- Unfortunately, DMF boundary ignores daylight savings, and the time of day varies across regions
    -- Report a reset well past end to make sure we don't drop quests early
    return time(darkmoonEnd) - (SI:GetServerOffset() * 3600)
end
