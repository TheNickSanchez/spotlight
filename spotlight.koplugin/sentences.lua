--[[--
Sentence boundaries for Spotlight.

Pure Lua, no KOReader dependencies, so it runs under plain LuaJIT on a desktop.

Input is the text of a stretch of the book cut into "chunks", the way
main.lua reads it from crengine: chunk i is the text between the end of
word i-1 and the end of word i, so every chunk ends with exactly one word.
crengine puts a "\n" wherever a block (paragraph, heading, list item, <br>)
ends, so a "\n" inside a chunk means a block boundary.

    Sentences.split(chunks, tail) -> list of sentences

Each sentence is a table:
    first, last  index of its first and last word (chunk)
    lead         characters of opening punctuation before the first word ("“", "(")
    trail        characters of closing punctuation after the last word (".”")
    words        number of words, counted by whitespace
    text         the sentence text
    block        block number (0 for the first block in the input)

`tail` is optional text after the last word (its trailing punctuation).
`opts.open_end` says the input stops in the middle of the text, so the last
sentence may be cut short: it is never merged into the one before it.

@module spotlight.sentences
--]]

local Sentences = {}

-- Words after which a period does not end a sentence. Compared in lower case,
-- with inner periods kept ("e.g", "u.s"). "May" is left out on purpose: it is
-- a full word, never an abbreviation, and is common at the end of sentences.
local ABBREVIATIONS = {}
for _, w in ipairs{
    "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e",
    "fig", "no", "vol", "approx",
    "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
    "u.s", "u.k", "a.m", "p.m",
} do
    ABBREVIATIONS[w] = true
end
Sentences.ABBREVIATIONS = ABBREVIATIONS

local function set(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end

local TERMINATORS = set{ ".", "!", "?", "…" }

local CLOSERS = set{ '"', "'", ")", "]", "}", "”", "’", "»", "›" }

-- Characters that may sit right before the first word of a sentence.
local OPENERS = set{ '"', "'", "(", "[", "{", "“", "‘", "«", "‹", "„", "‚", "¿", "¡", "—", "–" }

local SPACES = set{
    " ", "\t", "\r", "\n",
    "\194\160",                      -- no-break space
    "\226\128\128", "\226\128\129", "\226\128\130", "\226\128\131", "\226\128\132",
    "\226\128\133", "\226\128\134", "\226\128\135", "\226\128\136", "\226\128\137",
    "\226\128\138",                  -- U+2000..U+200A
    "\226\128\175",                  -- narrow no-break space
    "\227\128\128",                  -- ideographic space
}

-- Non-ASCII characters that are punctuation, not letters.
local PUNCTUATION = set{
    "”", "’", "»", "›", "“", "‘", "«", "‹", "„", "‚", "¿", "¡", "—", "–", "‐", "‑", "‒", "―",
    "…", "·", "•", "§", "¶", "†", "‡", "′", "″", "°",
}

--- Split a UTF-8 string into a list of characters.
local function utf8Chars(s, out)
    out = out or {}
    local i, n = 1, #s
    while i <= n do
        local b = s:byte(i)
        local len = 1
        if b >= 0xF0 then len = 4
        elseif b >= 0xE0 then len = 3
        elseif b >= 0xC0 then len = 2
        end
        out[#out + 1] = s:sub(i, i + len - 1)
        i = i + len
    end
    return out
end
Sentences.utf8Chars = utf8Chars

local function codepoint(c)
    local b1, b2, b3, b4 = c:byte(1, 4)
    if b1 < 0x80 then return b1 end
    if b1 < 0xE0 then return (b1 - 0xC0) * 0x40 + (b2 - 0x80) end
    if b1 < 0xF0 then return (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80) end
    return (b1 - 0xF0) * 0x40000 + (b2 - 0x80) * 0x1000 + (b3 - 0x80) * 0x40 + (b4 - 0x80)
end

local function isSpace(c)
    return c ~= nil and SPACES[c] == true
end

--- Letters, digits and hyphens, like crengine's word characters.
local function isWordChar(c)
    if c == nil then return false end
    if #c == 1 then
        return c:find("^[%w%-]") ~= nil
    end
    return not SPACES[c] and not PUNCTUATION[c]
end
Sentences.isWordChar = isWordChar

-- Lower and upper case for Latin, Latin-1, Latin Extended-A, Greek and Cyrillic.
-- Anything else (CJK, digits, symbols) is neither.
local function isLower(c)
    if c == nil then return false end
    local cp = codepoint(c)
    if cp >= 0x61 and cp <= 0x7A then return true end
    if cp >= 0xDF and cp <= 0xFF then return cp ~= 0xF7 end
    if cp >= 0x100 and cp <= 0x17F then return cp % 2 == 1 end
    if cp >= 0x3B1 and cp <= 0x3C9 then return true end
    if cp >= 0x430 and cp <= 0x45F then return true end
    return false
end

local function isUpper(c)
    if c == nil then return false end
    local cp = codepoint(c)
    if cp >= 0x41 and cp <= 0x5A then return true end
    if cp >= 0xC0 and cp <= 0xDE then return cp ~= 0xD7 end
    if cp >= 0x100 and cp <= 0x17F then return cp % 2 == 0 end
    if cp >= 0x391 and cp <= 0x3A9 then return true end
    if cp >= 0x400 and cp <= 0x42F then return true end
    return false
end
Sentences.isLower = isLower
Sentences.isUpper = isUpper

--- Count words: whitespace-separated runs that contain a letter or digit.
function Sentences.countWords(text)
    local n = 0
    local chars = utf8Chars(text)
    local in_word, has_letter = false, false
    for i = 1, #chars + 1 do
        local c = chars[i]
        if c == nil or isSpace(c) then
            if in_word and has_letter then n = n + 1 end
            in_word, has_letter = false, false
        else
            in_word = true
            if isWordChar(c) then has_letter = true end
        end
    end
    return n
end

--- The word just before position k (exclusive), without opening punctuation.
local function wordBefore(chars, k)
    local i = k - 1
    while i >= 1 and not isSpace(chars[i]) do i = i - 1 end
    local j = i + 1
    while j < k and (OPENERS[chars[j]] or CLOSERS[chars[j]]) do j = j + 1 end
    return table.concat(chars, "", j, k - 1)
end

--- Is the terminator run ending at chars[j] (after any closing quotes) a sentence end?
-- `k` is where the terminator run starts.
local function endsSentence(chars, k, j)
    local nxt = chars[j + 1]
    -- Must be followed by whitespace or the end of the text. This also keeps
    -- decimals (3.5) and inner periods (e.g.) together.
    if nxt ~= nil and not isSpace(nxt) then
        return false
    end
    -- A single period after an abbreviation or an initial.
    if chars[k] == "." and not TERMINATORS[chars[k + 1]] then
        local w = wordBefore(chars, k)
        if ABBREVIATIONS[w:lower()] then
            return false
        end
        local wchars = utf8Chars(w)
        if #wchars == 1 and isUpper(wchars[1]) then
            return false
        end
    end
    -- Next letter in lower case: the sentence goes on ("Wait… what?").
    local i = j + 1
    while chars[i] ~= nil and isSpace(chars[i]) do
        if chars[i] == "\n" then return true end
        i = i + 1
    end
    while chars[i] ~= nil and OPENERS[chars[i]] do i = i + 1 end
    if isLower(chars[i]) then
        return false
    end
    return true
end

--- Split chunks into sentences. See the module comment.
function Sentences.split(chunks, tail, opts)
    opts = opts or {}
    -- Flatten into characters, remembering where each chunk (word) ends.
    local chars = {}
    local word_end = {}
    for i, chunk in ipairs(chunks) do
        utf8Chars(chunk, chars)
        word_end[i] = #chars
    end
    if tail then utf8Chars(tail, chars) end
    local n = #chars

    -- Find spans {start, stop, block} of sentence candidates.
    local spans = {}
    local block = 0
    local start = 1
    local function closeSpan(stop, next_start)
        -- Trim whitespace on both ends.
        local s, e = start, stop
        while s <= e and isSpace(chars[s]) do s = s + 1 end
        while e >= s and isSpace(chars[e]) do e = e - 1 end
        if s <= e then
            spans[#spans + 1] = { start = s, stop = e, block = block }
        end
        start = next_start
    end
    local k = 1
    while k <= n do
        local c = chars[k]
        if c == "\n" then
            closeSpan(k - 1, k + 1)
            block = block + 1
            k = k + 1
        elseif TERMINATORS[c] then
            local j = k
            while TERMINATORS[chars[j + 1]] do j = j + 1 end
            while CLOSERS[chars[j + 1]] do j = j + 1 end
            if endsSentence(chars, k, j) then
                closeSpan(j, j + 1)
            end
            k = j + 1
        else
            k = k + 1
        end
    end
    closeSpan(n, n + 1)

    -- Map spans to words. A span gets the words whose end falls inside it.
    local raw = {}
    local w = 1
    for _, span in ipairs(spans) do
        while w <= #word_end and word_end[w] < span.start do w = w + 1 end
        local first = w
        while w <= #word_end and word_end[w] <= span.stop do w = w + 1 end
        local last = w - 1
        if last >= first then
            raw[#raw + 1] = {
                first = first, last = last,
                start = span.start, stop = span.stop, block = span.block,
            }
        end
    end

    local function finish(s)
        -- Opening punctuation: characters before the first letter of the span,
        -- never past the first word's end.
        local lead = 0
        local i = s.start
        while i < word_end[s.first] and not isWordChar(chars[i]) and not isSpace(chars[i]) do
            lead = lead + 1
            i = i + 1
        end
        s.lead = lead
        s.trail = s.stop - word_end[s.last]
        s.text = table.concat(chars, "", s.start, s.stop)
        s.words = Sentences.countWords(s.text)
        return s
    end
    for _, s in ipairs(raw) do finish(s) end

    -- Merge one-word fragments into the previous sentence of the same block,
    -- or into the next one when the fragment opens its block.
    local out = {}
    local carry = nil
    for idx, s in ipairs(raw) do
        if carry then
            s.first, s.start = carry.first, carry.start
            finish(s)
            carry = nil
        end
        local prev = out[#out]
        local nxt = raw[idx + 1]
        local cut_short = opts.open_end and idx == #raw
        if cut_short then
            out[#out + 1] = s
        elseif s.words <= 1 and prev and prev.block == s.block then
            prev.last, prev.stop = s.last, s.stop
            finish(prev)
        elseif s.words <= 1 and nxt and nxt.block == s.block then
            carry = s
        else
            out[#out + 1] = s
        end
    end

    for _, s in ipairs(out) do
        s.start, s.stop = nil, nil
    end
    return out
end

--- Cut plain text into chunks the way crengine walks words (for tests and tools).
-- Returns chunks, tail.
function Sentences.chunk(text)
    local chars = utf8Chars(text)
    local chunks = {}
    local buf = {}
    for i, c in ipairs(chars) do
        buf[#buf + 1] = c
        if isWordChar(c) and not isWordChar(chars[i + 1]) then
            chunks[#chunks + 1] = table.concat(buf)
            buf = {}
        end
    end
    return chunks, table.concat(buf)
end

--- Convenience: split plain text and return the sentence texts.
function Sentences.splitText(text)
    local chunks, tail = Sentences.chunk(text)
    local list = Sentences.split(chunks, tail)
    local texts = {}
    for i, s in ipairs(list) do texts[i] = s.text end
    return texts, list
end

return Sentences
