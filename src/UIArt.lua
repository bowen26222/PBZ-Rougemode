local Native = require('Native')
local Locale = require('Locale')
local weapon_icon_bounds = require('WeaponIconBounds')
local supply_icon_bounds = require('SupplyIconBounds')
local UIArt = {}
UIArt.__index = UIArt

local source = debug.getinfo(1, 'S').source:gsub('^@', ''):gsub('\\', '/')
local directory = assert(source:match('^(.*)/[^/]+/UIArt%.lua$'), 'Cannot locate installed UI artwork')
local artwork_directory = directory .. '/ui/'

function UIArt.new(world)
    return setmetatable({world = world, icons = {}, hud_textures = {}}, UIArt)
end

local function load_artwork(world, filename)
    local path = artwork_directory .. filename
    local texture = Native.cdo('/Script/Engine.Default__KismetRenderingLibrary')
        :ImportFileAsTexture2D(world, path)
    assert(Native.valid(texture), 'Cannot import UI artwork: ' .. path)
    return texture
end

function UIArt:background()
    -- Both languages keep the original illustrated backdrop and baked game logo.
    if not Native.valid(self.background_texture) then
        local texture = load_artwork(self.world, 'background-ink-grayscale.png')
        -- Brightened artwork carries its own 0..153 alpha (60%); no dark veil.
        self.background_texture = Native.retain(texture)
    end
    return self.background_texture
end

function UIArt:modal_background()
    if not Native.valid(self.modal_texture) then
        self.modal_texture = Native.retain(load_artwork(self.world, 'modal-ink.png'))
    end
    return self.modal_texture
end

function UIArt:shop_title()
    return self:hud_texture(Locale.text('shop-title.png', 'shop-title-en.png'))
end

function UIArt:hud_texture(filename)
    local texture = self.hud_textures[filename]
    if not Native.valid(texture) then
        texture = Native.retain(load_artwork(self.world, filename))
        self.hud_textures[filename] = texture
    end
    return texture
end

function UIArt:icon(path)
    assert(type(path) == 'string' and path ~= '', 'Shop item is missing its native icon')
    local texture = self.icons[path]
    if not Native.valid(texture) then
        texture = Native.load_object(path)
        assert(texture:IsA('/Script/Engine.Texture2D'), 'Shop icon is not a native Texture2D: ' .. path)
        self.icons[path] = texture
    end
    return texture, weapon_icon_bounds[path] or supply_icon_bounds[path]
end

function UIArt:preload_shop(model)
    -- Use the render accessors so preparation and first open share retained
    -- textures; import only the active language's artwork and actual offers.
    self:background()
    self:hud_texture('shop-icon-ink.png')
    self:shop_title()
    for index, section in ipairs(model.sections) do
        self:hud_texture('shop-heading-' .. index .. Locale.text('.png', '-en.png'))
        for _, offer in ipairs(section.offers) do self:icon(offer.icon) end
    end
    for _, offer in ipairs(model.fixed) do self:icon(offer.icon) end
end

function UIArt:destroy()
    Native.release(self.background_texture)
    Native.release(self.modal_texture)
    for _, texture in pairs(self.hud_textures) do Native.release(texture) end
    self.background_texture, self.modal_texture = nil, nil
    self.world, self.icons, self.hud_textures = nil, nil, nil
end

return UIArt
