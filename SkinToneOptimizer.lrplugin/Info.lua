--[[
  Claude AI Skin Tone Optimizer for Lightroom Classic
  Info.lua — Plugin manifest

  Reads the selected photo's develop settings + JPEG preview,
  sends both to Claude, and applies optimised White Balance and
  HSL Color Mixer settings tuned for skin tones.
--]]

return {

    LrSdkVersion        = 6.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = 'com.frankminjarez.skintoneopti',
    LrPluginName        = LOC '$$$/SkinToneOpti/PluginName=Claude AI Skin Tone Optimizer',
    LrPluginInfoUrl     = 'https://frankminjarez.com',

    LrExportMenuItems = {
        {
            title       = LOC '$$$/SkinToneOpti/Menu/Optimize=Optimize Skin Tones with Claude AI',
            file        = 'SkinToneOptimizer.lua',
            enabledWhen = 'photosSelected',
        },
        {
            title = LOC '$$$/SkinToneOpti/Menu/Settings=Skin Tone Optimizer Settings\226\128\166',
            file  = 'SettingsDialog.lua',
        },
    },

    VERSION = { major = 1, minor = 0, revision = 0, build = 1 },
}
