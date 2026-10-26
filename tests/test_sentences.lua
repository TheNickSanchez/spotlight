local Sentences = require("sentences")
local test, eq, ok = T.test, T.eq, T.ok

local split = Sentences.splitText

test("ends at . ! ? and …", function()
    eq(split("One two three. Four five six! Seven eight nine? Ten eleven twelve… Done and dusted."), {
        "One two three.", "Four five six!", "Seven eight nine?", "Ten eleven twelve…", "Done and dusted.",
    })
end)

test("closing quotes and brackets stay with the sentence", function()
    eq(split('He said "go home." Then he left. (It was late.) We slept.'), {
        'He said "go home."', "Then he left.", "(It was late.)", "We slept.",
    })
    eq(split("“Are you sure?” He nodded slowly."), { "“Are you sure?”", "He nodded slowly." })
end)

test("needs whitespace after the terminator", function()
    eq(split("Version 3.5 is out now. It works well."), { "Version 3.5 is out now.", "It works well." })
    eq(split("See example.com for more. Then come back."), { "See example.com for more.", "Then come back." })
end)

test("abbreviations do not end a sentence", function()
    eq(split("Mr. Smith met Dr. Jones at St. Paul's today. They talked."), {
        "Mr. Smith met Dr. Jones at St. Paul's today.", "They talked.",
    })
    eq(split("We need eggs, milk, etc. But not now, please."), { "We need eggs, milk, etc. But not now, please." })
    eq(split("It ran from Jan. To Dec. Of that year it rained."), { "It ran from Jan. To Dec. Of that year it rained." })
    eq(split("She moved to the U.S. In June it snowed."), { "She moved to the U.S. In June it snowed." })
    eq(split("Meet at 9 a.m. Or later is fine."), { "Meet at 9 a.m. Or later is fine." })
    eq(split("See Fig. 3 and Vol. 2 for details. Thanks for reading."), {
        "See Fig. 3 and Vol. 2 for details.", "Thanks for reading.",
    })
end)

test("inner periods in e.g. and i.e. stay together", function()
    eq(split("Use a tool, e.g. a hammer. Or a rock, i.e. anything hard."), {
        "Use a tool, e.g. a hammer.", "Or a rock, i.e. anything hard.",
    })
end)

test("single capital initials", function()
    eq(split("J. R. R. Tolkien wrote it. Everyone read it."), { "J. R. R. Tolkien wrote it.", "Everyone read it." })
end)

test("next character in lower case keeps the sentence going", function()
    eq(split("“Why?” she asked quietly. Wait… what happened here?"), {
        "“Why?” she asked quietly.", "Wait… what happened here?",
    })
end)

test("the end of a block always ends a sentence", function()
    eq(split("Chapter One\nIt was a dark night. Rain fell\nNew paragraph starts here."), {
        "Chapter One", "It was a dark night.", "Rain fell", "New paragraph starts here.",
    })
end)

test("headings and list items are their own units", function()
    eq(split("Prologue\nThe first item\nThe second item\nBody text goes here."), {
        "Prologue", "The first item", "The second item", "Body text goes here.",
    })
end)

test("one-word fragments merge into the previous sentence", function()
    eq(split("He opened the door. Nothing. Then he closed it again."), {
        "He opened the door. Nothing.", "Then he closed it again.",
    })
end)

test("a one-word fragment that opens a block merges into the next", function()
    eq(split("End of a paragraph here.\nYes. She smiled at him."), {
        "End of a paragraph here.", "Yes. She smiled at him.",
    })
end)

test("never merges across blocks", function()
    eq(split("A whole sentence here.\nOkay.\nAnother full sentence."), {
        "A whole sentence here.", "Okay.", "Another full sentence.",
    })
end)

test("non-ASCII text", function()
    eq(split("Él dijo «sí». Después se fue a casa."), { "Él dijo «sí».", "Después se fue a casa." })
    eq(split("Déjà vu again. Élan is French."), { "Déjà vu again.", "Élan is French." })
end)

test("multiple terminators", function()
    eq(split("Really?! I can't believe it... Neither can I."), {
        "Really?! I can't believe it...", "Neither can I.",
    })
end)

test("word counts", function()
    eq(Sentences.countWords("It's a well-known “fact”, isn't it?"), 6)
    eq(Sentences.countWords("— — —"), 0)
end)

-- The fields main.lua uses to place the highlight.
test("first, last, lead and trail", function()
    local chunks, tail = Sentences.chunk('He left. “Go now,” she said. ')
    -- crengine-style words: He | left | Go | now | she | said
    eq(#chunks, 6)
    local list = Sentences.split(chunks, tail)
    eq(#list, 2)
    eq({ list[1].first, list[1].last, list[1].lead, list[1].trail }, { 1, 2, 0, 1 })
    eq({ list[2].first, list[2].last, list[2].lead, list[2].trail }, { 3, 6, 1, 1 })
    eq(list[2].words, 4)
end)

test("apostrophes split crengine words but not sentences", function()
    local chunks = Sentences.chunk("Don't stop. It's fine.")
    eq(chunks[1], "Don")
    eq(chunks[2], "'t")
    local texts, list = split("Don't stop. It's fine.")
    eq(texts, { "Don't stop.", "It's fine." })
    eq(list[1].words, 2)
end)

test("a sentence cut off at the end of the input is kept", function()
    eq(split("First sentence ends here. The second one runs off the"), {
        "First sentence ends here.", "The second one runs off the",
    })
end)

test("a cut-short last sentence is not merged into the one before", function()
    local chunks, tail = Sentences.chunk("He thought about it. Nothing. She")
    local list = Sentences.split(chunks, tail, { open_end = true })
    eq(#list, 2)
    eq(list[1].text, "He thought about it. Nothing.")
    eq(list[2].text, "She")
end)

test("empty and punctuation-only input", function()
    eq(split(""), {})
    eq(split("* * *"), {})
    eq(split("\n\n"), {})
end)

test("blocks are numbered", function()
    local _, list = split("One two three.\nFour five six. Seven eight nine.")
    eq({ list[1].block, list[2].block, list[3].block }, { 0, 1, 1 })
end)

ok(true)
