local Stats = require("stats")
local Pace = require("pace")
local test, eq, ok = T.test, T.eq, T.ok
local cfg = Pace.config

local START = os.time{ year = 2026, month = 10, day = 25, hour = 20, min = 0, sec = 0 }

local function session(pace)
    return Stats.newSession{ book_title = "Pride and Prejudice", started_at = START, pace_wpm = pace or 200, cfg = cfg }
end

test("reading time adds up the time between moves of the light", function()
    local s = session()
    s:activity(0, "manual")
    s:activity(5000, "manual")
    s:activity(11000, "manual")
    eq(s.active_ms, 11000)
end)

test("gaps over 90 seconds are not reading time", function()
    local s = session()
    s:activity(0, "manual")
    s:activity(5000, "manual")
    s:activity(5000 + 91000, "manual")   -- put the Kindle down for a while
    s:activity(5000 + 91000 + 4000, "manual")
    eq(s.active_ms, 9000)
    s:activity(5000 + 91000 + 4000 + 90000, "manual") -- exactly 90 s still counts
    eq(s.active_ms, 99000)
end)

test("time is split between Manual and Auto by the mode it was spent in", function()
    local s = session()
    s:activity(0, "manual")
    s:activity(6000, "auto")     -- 6 s of Manual reading, then Auto starts
    s:activity(10000, "auto")    -- 4 s of Auto
    s:activity(13000, "manual")  -- 3 s of Auto, then back to Manual
    eq({ s.manual_ms, s.auto_ms }, { 6000, 7000 })
end)

test("a record has plain, descriptive fields", function()
    local s = session(212)
    s:activity(0, "manual", START)
    for i = 1, 10 do
        s:activity(i * 6000, "manual", START + i * 6)
        s:sentenceRead(20)
    end
    s:count("backs")
    s:count("holds")
    s:count("skip_aheads")
    s:count("auto_adjust_changes")
    local r = s:record(228)
    eq(r.date, "2026-10-25")
    eq(r.started_at, "2026-10-25T20:00:00")
    eq(r.ended_at, "2026-10-25T20:01:00")
    eq(r.book_title, "Pride and Prejudice")
    eq(r.active_seconds, 60)
    eq(r.sentences, 10)
    eq(r.words, 200)
    eq(r.average_wpm, 200)
    eq({ r.holds, r.backs, r.skip_aheads, r.auto_adjust_changes }, { 1, 1, 1, 1 })
    eq({ r.starting_pace_wpm, r.ending_pace_wpm }, { 212, 228 })
    -- Every field is documented, and every documented field is there.
    local documented = {}
    for _i, f in ipairs(Stats.FIELDS) do
        documented[f[1]] = true
        ok(r[f[1]] ~= nil, "missing " .. f[1])
    end
    for k in pairs(r) do ok(documented[k], "undocumented field " .. k) end
end)

test("nothing read: nothing saved", function()
    eq(session():record(200), nil)
end)

test("a session saved while running is replaced when it ends", function()
    local s = session()
    s:activity(0, "manual")
    s:sentenceRead(10)
    local list = {}
    Stats.upsert(list, s:record(200))
    s:sentenceRead(10)
    Stats.upsert(list, s:record(200))
    eq(#list, 1)
    eq(list[1].sentences, 2)
    Stats.upsert(list, { id = "another" })
    eq(#list, 2)
end)

-- Summaries -------------------------------------------------------------------

local function rec(date, minutes, sentences, words, holds, backs)
    return { id = date .. minutes, date = date, active_seconds = minutes * 60, sentences = sentences,
             words = words, holds = holds or 0, backs = backs or 0 }
end

test("days are counted across month ends and clock changes", function()
    eq(Stats.dayNumber("2026-11-01") - Stats.dayNumber("2026-10-31"), 1)
    eq(Stats.dayNumber("2026-03-30") - Stats.dayNumber("2026-03-28"), 2)
end)

test("today, the last 7 days and the last 30 days, each against the period before", function()
    local records = {
        rec("2026-10-25", 20, 200, 4000, 2, 4),  -- today
        rec("2026-10-24", 10, 100, 1800, 3, 3),  -- yesterday
        rec("2026-10-20", 30, 300, 6000),         -- this week
        rec("2026-10-15", 30, 300, 5400),         -- the week before
        rec("2026-09-01", 60, 600, 9000),         -- 54 days ago: the 30 days before
        rec("2026-06-01", 60, 600, 9000),         -- too old for any period
    }
    local report = Stats.report(records, "2026-10-25")
    local today, week, month = report[1], report[2], report[3]
    eq(today.key, "today")
    eq(today.current.minutes, 20)
    eq(today.current.sentences, 200)
    eq(today.current.wpm, 200)
    eq(today.current.stops_per_100, 3)
    eq(today.previous.wpm, 180)              -- yesterday
    eq(today.previous.stops_per_100, 6)
    eq(week.current.minutes, 60)             -- today, yesterday and the 20th
    eq(week.current.sessions, 3)
    eq(week.previous.minutes, 30)            -- the 15th
    eq(month.current.minutes, 90)
    eq(month.previous.minutes, 60)           -- 1 September
end)

test("no reading in a period: no pace and no stop rate", function()
    local report = Stats.report({}, "2026-10-25")
    eq(report[1].current.minutes, 0)
    eq(report[1].current.wpm, nil)
    eq(report[1].current.stops_per_100, nil)
end)
