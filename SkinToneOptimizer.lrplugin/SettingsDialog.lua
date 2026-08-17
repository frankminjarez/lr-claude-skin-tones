--[[
  Claude AI Skin Tone Optimizer for Lightroom Classic
  SettingsDialog.lua — Preferences UI

  Stores settings in Lightroom's per-plugin prefs (LrPrefs),
  which persist across Lightroom restarts.
--]]

local LrBinding         = import 'LrBinding'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrPrefs           = import 'LrPrefs'
local LrTasks           = import 'LrTasks'
local LrView            = import 'LrView'

local pluginPrefs = LrPrefs.prefsForPlugin()

-- Available Claude models (user can type a custom value too)
local MODELS = {
    'claude-opus-4-5',
    'claude-sonnet-4-5',
    'claude-haiku-4-5',
}

-- Thumbnail sizes offered in the dropdown
local THUMB_SIZES = { '512', '768', '1024', '1536', '2048' }

LrTasks.startAsyncTask(function()
    LrFunctionContext.callWithContext('skinToneSettingsDialog', function(context)

        local f     = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        -- Populate from saved prefs (or use sensible defaults)
        props.apiKey        = pluginPrefs.claudeApiKey  or ''
        props.model         = pluginPrefs.claudeModel   or 'claude-opus-4-5'
        props.thumbnailSize = tostring(pluginPrefs.thumbnailSize or 1024)

        -- ── UI layout ──────────────────────────────────────────────
        local contents = f:column {
            bind_to_object = props,
            spacing        = f:dialog_spacing(),

            -- API Configuration
            f:group_box {
                title           = 'API Configuration',
                fill_horizontal = 1,

                f:column {
                    spacing         = f:label_spacing(),
                    fill_horizontal = 1,

                    f:row {
                        spacing = f:label_spacing(),
                        f:static_text {
                            title     = 'API Key:',
                            width     = LrView.share 'lbl',
                            alignment = 'right',
                        },
                        f:password_field {
                            value           = LrView.bind 'apiKey',
                            fill_horizontal = 1,
                            width_in_chars  = 48,
                            tooltip         = 'Your Anthropic API key (sk-ant-...)',
                        },
                    },

                    f:row {
                        f:static_text {
                            title = '',
                            width = LrView.share 'lbl',
                        },
                        f:static_text {
                            title      = 'Get your key at console.anthropic.com',
                            text_color = LrView.blue,
                            font       = '<system/small>',
                        },
                    },

                    f:spacer { height = 4 },

                    f:row {
                        spacing = f:label_spacing(),
                        f:static_text {
                            title     = 'Model:',
                            width     = LrView.share 'lbl',
                            alignment = 'right',
                        },
                        f:combo_box {
                            value          = LrView.bind 'model',
                            items          = MODELS,
                            width_in_chars = 30,
                            tooltip        = 'claude-opus-4-5 is most capable for colour analysis. You can type a custom model ID.',
                        },
                    },

                    f:row {
                        f:static_text {
                            title = '',
                            width = LrView.share 'lbl',
                        },
                        f:static_text {
                            title = 'Opus = best colour analysis  |  Sonnet = faster & cheaper  |  Haiku = fastest',
                            font  = '<system/small>',
                        },
                    },
                },
            },

            -- Image Quality
            f:group_box {
                title           = 'Image Analysis Quality',
                fill_horizontal = 1,

                f:column {
                    spacing = f:label_spacing(),

                    f:row {
                        spacing = f:label_spacing(),
                        f:static_text {
                            title     = 'Preview size:',
                            width     = LrView.share 'lbl',
                            alignment = 'right',
                        },
                        f:combo_box {
                            value          = LrView.bind 'thumbnailSize',
                            items          = THUMB_SIZES,
                            width_in_chars = 8,
                            tooltip        = 'Longer edge in pixels sent to Claude. Higher = better skin tone analysis, larger API payload.',
                        },
                        f:static_text {
                            title = 'px  (longer edge of the preview sent to Claude)',
                        },
                    },

                    f:row {
                        f:static_text {
                            title = '',
                            width = LrView.share 'lbl',
                        },
                        f:static_text {
                            title = '1024 px is a good default. If previews are missing, build them first in  Library \226\150\184 Previews.',
                            font  = '<system/small>',
                        },
                    },
                },
            },

            -- About
            f:group_box {
                title           = 'About',
                fill_horizontal = 1,

                f:column {
                    spacing = f:label_spacing(),

                    f:static_text {
                        title = 'This plugin adjusts only White Balance (Temperature + Tint) and the\nHSL Color Mixer. All other develop settings are left untouched.',
                        font  = '<system/small>',
                    },
                    f:spacer { height = 2 },
                    f:static_text {
                        title = 'Use Develop \226\150\184 History to revert changes if needed.',
                        font  = '<system/small>',
                    },
                },
            },
        }

        -- Show dialog
        local result = LrDialogs.presentModalDialog({
            title      = 'Claude AI Skin Tone Optimizer \226\128\148 Settings',
            contents   = contents,
            actionVerb = 'Save',
            cancelVerb = 'Cancel',
        })

        if result == 'ok' then
            -- Validate API key
            local key = props.apiKey:match('^%s*(.-)%s*$')  -- trim
            if key == '' then
                LrDialogs.message(
                    'Settings not saved',
                    'Please enter your Anthropic API key.',
                    'warning'
                )
                return
            end

            -- Validate thumbnail size
            local sz = tonumber(props.thumbnailSize)
            if not sz or sz < 256 or sz > 4096 then
                LrDialogs.message(
                    'Settings not saved',
                    'Preview size must be a number between 256 and 4096.',
                    'warning'
                )
                return
            end

            -- Persist
            pluginPrefs.claudeApiKey   = key
            pluginPrefs.claudeModel    = props.model
            pluginPrefs.thumbnailSize  = sz

            LrDialogs.message(
                'Claude AI Skin Tone Optimizer',
                'Settings saved.',
                'info'
            )
        end

    end)
end)
