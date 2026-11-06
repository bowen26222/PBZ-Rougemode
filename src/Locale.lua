local Native = require('Native')
local Locale = {}

-- Text language, not OS culture, number formatting locale, or voice language.
-- Query when presenting text so changes made in the game's settings take effect.
function Locale.is_chinese()
    local language = Native.name(Native.cdo('/Script/Engine.Default__KismetInternationalizationLibrary')
        :GetCurrentLanguage()):lower():gsub('_', '-')
    return language == 'zh' or language:sub(1, 3) == 'zh-'
end

function Locale.language()
    return Locale.is_chinese() and 'zh' or 'en'
end

function Locale.text(chinese, english)
    if Locale.is_chinese() then return chinese end
    return english
end

return Locale
