local Native = require('Native')
local Locale = require('Locale')
local HudUI = {}
HudUI.__index = HudUI

local calligraphy_path = '/Game/PBZContent/UI/Fonts/ZH_ZiKuTangKuangShanKaiShuJF_Font.ZH_ZiKuTangKuangShanKaiShuJF_Font'
local english_title_path = '/Game/PBZContent/UI/Fonts/EN_AlverataCYR_Medium_Title_Font.EN_AlverataCYR_Medium_Title_Font'
local ivory = {R = 0.88, G = 0.86, B = 0.77, A = 1}
local muted = {R = 0.56, G = 0.57, B = 0.53, A = 1}
local cleared = {R = 0.65, G = 0.67, B = 0.61, A = 1}
local angles = {45, 135, 270} -- North-facing texture: NE, SE, west.
local dial = {x = 28, y = 110, size = 256, padding = 28}
-- Ink-center offsets measured from the native font at the displayed sizes.
local boss_status_offset = {pending = -0.5, ready = 0, combat = -0.5, cleared = -1}

local function place(canvas, widget, x, y, width, height)
    local slot = canvas:AddChildToCanvas(widget)
    slot:SetPosition({X = x, Y = y})
    slot:SetSize({X = width, Y = height})
    return widget
end

local function color(text, value)
    text:SetColorAndOpacity({SpecifiedColor = value, ColorUseRule = 0})
end

function HudUI:widget(class)
    local widget = Native.construct('/Script/UMG.' .. class, self.tree)
    widget:SetVisibility(3) -- HitTestInvisible; the HUD never captures game input.
    return widget
end

function HudUI:image(filename, x, y, width, height)
    local image = self:widget('Image')
    image:SetBrushFromTexture(self.art:hud_texture(filename), true)
    return place(self.canvas, image, x, y, width, height)
end

function HudUI:text(value, size, x, y, width, height, fit)
    local text = self:widget('TextBlock')
    text:SetFont(self.font)
    local font = text.Font
    font.FontObject = self.display_font
    font.TypefaceFontName = FName('Default')
    font.Size = size
    font.FontMaterial = nil
    font.OutlineSettings.OutlineMaterial = nil
    font.OutlineSettings.OutlineSize = 1
    font.OutlineSettings.OutlineColor = {R = 0.01, G = 0.015, B = 0.015, A = 1}
    font.LetterSpacing = 0
    font.bForceMonospaced = false
    text:SetFont(font)
    text:SetText(Native.text(value))
    text:SetAutoWrapText(false)
    text:SetJustification(1) -- ETextJustify::Center.
    text:SetShadowColorAndOpacity({R = 0, G = 0, B = 0, A = 0.9})
    text:SetShadowOffset({X = 1, Y = 1})
    color(text, ivory)
    if fit or not Locale.is_chinese() then
        -- Each compact boss strip fits its full native name on one line.
        -- DownOnly preserves the normal font size for shorter names.
        local scale = self:widget('ScaleBox')
        scale:SetStretch(2) -- ScaleToFit.
        scale:SetStretchDirection(1) -- DownOnly.
        scale:SetContent(text)
        place(self.canvas, scale, x, y, width, height)
        return text, scale
    end
    return place(self.canvas, text, x, y, width, height)
end

-- The owner supplies its existing passive widget tree and manages its lifetime,
-- viewport attachment and visibility. No page, layer or input is created here.
function HudUI.new(tree, canvas, art, font)
    local self = setmetatable({tree = tree, canvas = canvas, art = art, font = font,
        values = {}, sectors = {}, captions = {}, progress = {}}, HudUI)
    self.display_font = Native.load_object(Locale.text(calligraphy_path, english_title_path))
    self:image('hud-floor-brush.png', 24, 24, 280, 56)
    self.floor = self:text('', 30, 38, 28, 244, 46)
    -- Enlarge the artwork around the label layout, not the text. Keep its top
    -- below the floor strip and move the labels with the new dial center.
    local x, y, size = dial.x - dial.padding, dial.y - dial.padding, dial.size + dial.padding * 2
    self:image('hud-dial.png', x, y, size, size)
    for index = 1, 3 do
        self.sectors[index] = self:image('hud-sector-' .. index .. '.png', x, y, size, size)
    end
    self.pointer = self:image('hud-pointer.png', x, y, size, size)
    self.pointer:SetRenderTransformPivot({X = 0.5, Y = 0.5})

    -- The right quarters are the mob waves; the entire left half is the boss.
    self.captions[1] = self:text(Locale.text('第一波', 'Wave 1'), 18, 178, 167, 72, 30)
    self.captions[2] = self:text(Locale.text('第二波', 'Wave 2'), 18, 178, 275, 72, 30)
    self.captions[3] = self:text(Locale.text('首领', 'Boss'), 25, 40, 210, 68, 36)
    self.progress[1] = self:text('', 13, 181, 198, 68, 22)
    self.progress[2] = self:text('', 13, 181, 306, 68, 22)
    self.progress[3], self.boss_progress_layout = self:text('', 13, 35, 246, 76, 22)
    self.state = self:text('', 18, 124, 214, 64, 28, true)
    self.detail = self:text('', 11, 128, 242, 56, 18, true)

    -- Boss names sit below the dial, each on its own compact brush.
    -- All headings, labels and strips share the dial's horizontal center.
    self.boss_heading = self:text('', 15, dial.x - 12, 398, dial.size + 24, 28)
    self.boss_names, self.boss_rows = {}, {}
    for index = 1, 2 do
        local y = 430 + (index - 1) * 50
        local brush = self:image('hud-boss-brush.png', dial.x, y, dial.size, 44)
        local text, label = self:text('', 17, dial.x + 12, y + 5, dial.size - 24, 34, true)
        self.boss_names[index] = text
        self.boss_rows[index] = {brush = brush, label = label, y = y}
        brush:SetVisibility(1)
        label:SetVisibility(1)
    end
    return self
end

function HudUI:set_text(key, widget, value)
    if self.values[key] == value then return end
    self.values[key] = value
    widget:SetText(Native.text(value))
end

-- During rest, wave denotes the completed wave: 2 means boss next and 3
-- means floor cleared. Opening preparation accepts Run.wave=0 or its HUD clamp=1.
-- During between, wave is the upcoming wave; during checkpoint it just ended.
function HudUI:update(model)
    local wave, phase = model.wave, model.phase
    local preview_next = phase == 'rest' and wave == 3
    local completed = wave - 1
    local target = wave
    local state, detail
    if phase == 'ready' then
        completed, target = 0, 1
        state, detail = Locale.text('待战', 'Ready'), Locale.text('第一波', 'Wave 1')
    elseif phase == 'rest' then
        if wave <= 1 then
            completed, target = 0, 1
            state, detail = Locale.text('备战', 'Prepare'), Locale.text('铃铛准备', 'At bell')
        elseif wave == 2 then
            completed, target = 2, 3
            state, detail = Locale.text('休整', 'Rest'), Locale.text('首领待战', 'Boss next')
        else
            completed, target = 3, 3
            state, detail = Locale.text('休整', 'Rest'), Locale.text('本层已清', 'Cleared')
        end
    elseif phase == 'between' then
        state = Locale.text('倒数', 'Get ready')
        detail = model.countdown ~= nil and string.format(Locale.text('%s 秒', '%s s'), model.countdown)
            or Locale.text('即将开战', 'Starting')
    elseif phase == 'combat' then
        state = Locale.text('交战', 'Fight')
        detail = model.remaining ~= nil and string.format(Locale.text('余 %s', '%s left'), model.remaining)
            or Locale.text('战斗中', 'In battle')
    elseif phase == 'checkpoint' then
        completed = wave
        state, detail = Locale.text('存档', 'Saving'), Locale.text('请稍候', 'Please wait')
    else
        error('Unsupported HUD phase: ' .. tostring(phase))
    end

    self:set_text('floor', self.floor, string.format(Locale.text('第 %s 层', 'Floor %s'), model.floor))
    self:set_text('state', self.state, state)
    self:set_text('detail', self.detail, detail)
    if self.target ~= target then
        self.pointer:SetRenderTransformAngle(angles[target])
        self.target = target
    end
    for index = 1, 3 do
        local status
        if index <= completed then status = 'cleared'
        elseif index == target then status = phase == 'combat' and 'combat' or 'ready'
        else status = 'pending' end
        local key = 'sector' .. index
        if self.values[key] ~= status then
            self.values[key] = status
            local is_done, is_active = index <= completed, index == target
            self.sectors[index]:SetRenderOpacity(is_done and 0.34 or (is_active and 1 or 0.10))
            color(self.captions[index], is_done and cleared or (is_active and ivory or muted))
            color(self.progress[index], is_done and cleared or (is_active and ivory or muted))
            local label
            if status == 'cleared' then label = Locale.text('已清', 'Cleared')
            elseif status == 'combat' then label = Locale.text('交战', 'Fighting')
            elseif status == 'ready' then label = Locale.text('待战', 'Ready')
            else label = Locale.text('未至', 'Ahead') end
            self.progress[index]:SetText(Native.text(label))
            if index == 3 then
                local layout = self.boss_progress_layout or self.progress[3]
                local offset = Locale.is_chinese() and boss_status_offset[status] or 0
                layout.Slot:SetPosition({X = 32 + offset, Y = 246})
            end
        end
    end
    -- A cleared dial stays on this floor; its compact strips announce the next
    -- planned floor instead. Missing second bosses never leave an empty brush.
    local names = preview_next
        and assert(model.next_boss_names, 'Cleared-floor HUD requires the next boss plan')
        or model.boss_names or {}
    self:set_text('boss_heading', self.boss_heading, preview_next
        and string.format(Locale.text('第 %s 层首领预告', 'Floor %s bosses'),
            assert(model.next_floor, 'Cleared-floor HUD requires the next floor'))
        or Locale.text('本层首领', 'This floor’s bosses'))
    for index = 1, 2 do
        local name, key = names[index] or '', 'boss' .. index
        if self.values[key] ~= name then
            local row = self.boss_rows[index]
            local visible = name ~= ''
            if visible then
                local width = math.min(dial.size, math.max(128, utf8.len(name) * 22 + 28))
                local x = dial.x + (dial.size - width) * 0.5
                row.brush.Slot:SetPosition({X = x, Y = row.y})
                row.brush.Slot:SetSize({X = width, Y = 44})
                row.label.Slot:SetPosition({X = x + 12, Y = row.y + 5})
                row.label.Slot:SetSize({X = width - 24, Y = 34})
            end
            row.brush:SetVisibility(visible and 3 or 1)
            row.label:SetVisibility(visible and 3 or 1)
            self:set_text(key, self.boss_names[index], name)
        end
    end
end

return HudUI
