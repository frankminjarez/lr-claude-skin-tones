--[[
  Claude AI Skin Tone Optimizer for Lightroom Classic
  SkinToneOptimizer.lua — Main action

  Flow for the selected photo:
    1. Read current Develop settings (White Balance + HSL) from the photo
    2. Request a JPEG thumbnail from Lightroom's preview cache
    3. Base64-encode the JPEG bytes
    4. POST image + current settings to the Anthropic Messages API (vision)
    5. Parse JSON response → optimised Temperature, Tint, 24 HSL sliders, reasoning
    6. Apply the new settings via catalog write access
    7. Show a summary dialog with the changes and Claude's reasoning

  Scope: ONLY White Balance (Temperature, Tint) and HSL Color Mixer.
         Exposure, tone curve, and all other panels are left untouched.
--]]

local LrApplication      = import 'LrApplication'
local LrDialogs          = import 'LrDialogs'
local LrFunctionContext  = import 'LrFunctionContext'
local LrHttp             = import 'LrHttp'
local LrPrefs            = import 'LrPrefs'
local LrProgressScope    = import 'LrProgressScope'
local LrTasks            = import 'LrTasks'
local LrStringUtils      = import 'LrStringUtils'
local LrView             = import 'LrView'

local json = require 'json'

local pluginPrefs = LrPrefs.prefsForPlugin()

-- ─────────────────────────────────────────────────────────
-- Base64 encoder (pure Lua — no external dependencies)
-- ─────────────────────────────────────────────────────────
local B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64Encode(data)
    local result  = {}
    local dataLen = #data
    local padding = (3 - (dataLen % 3)) % 3

    for i = 1, dataLen + padding, 3 do
        local b1 = data:byte(i)     or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0

        local n  = b1 * 65536 + b2 * 256 + b3

        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096)   % 64
        local c3 = math.floor(n / 64)     % 64
        local c4 = n % 64

        result[#result + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
        result[#result + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
        result[#result + 1] = B64_CHARS:sub(c3 + 1, c3 + 1)
        result[#result + 1] = B64_CHARS:sub(c4 + 1, c4 + 1)
    end

    local encoded = table.concat(result)

    if padding == 2 then
        encoded = encoded:sub(1, #encoded - 2) .. '=='
    elseif padding == 1 then
        encoded = encoded:sub(1, #encoded - 1) .. '='
    end

    return encoded
end

-- ─────────────────────────────────────────────────────────
-- JPEG dimension reader (pure Lua — parses SOF marker)
-- Returns width, height or nil, nil on failure
-- ─────────────────────────────────────────────────────────
local function getJpegDimensions(data)
    if not data or #data < 4 then return nil, nil end
    -- Must start with SOI marker FF D8
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil, nil end

    local i = 3
    while i <= #data - 8 do
        if data:byte(i) ~= 0xFF then break end
        local marker = data:byte(i + 1)
        -- SOF markers carry image dimensions: C0-C3, C5-C7, C9-CB, CD-CF
        -- (exclude C4=DHT, C8=JPG, CC=DAC which have the same byte range)
        if marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
           and marker >= 0xC0 and marker <= 0xCF then
            -- SOF layout: FF Cn | length(2) | precision(1) | height(2) | width(2)
            local h = data:byte(i + 5) * 256 + data:byte(i + 6)
            local w = data:byte(i + 7) * 256 + data:byte(i + 8)
            return w, h
        end
        -- Skip segment: length field at i+2 includes itself (2 bytes)
        local segLen = data:byte(i + 2) * 256 + data:byte(i + 3)
        if segLen < 2 then break end  -- corrupt
        i = i + 2 + segLen
    end
    return nil, nil
end

-- Anthropic hard limits
local MAX_IMAGE_DIM   = 7999
local MAX_IMAGE_BYTES = 9 * 1024 * 1024   -- 9 MB — gives headroom under the 10 MB API cap

-- ─────────────────────────────────────────────────────────
-- Async thumbnail retrieval
--
-- catalog:setSelectedPhotos() asserts when called from inside an async task
-- that has an active progress scope (Lightroom SDK context restriction).
-- When the preview is stale, we retry briefly then surface a clear instruction
-- asking the user to manually click away and back — that is the reliable fix.
-- ─────────────────────────────────────────────────────────
local function getPhotoThumbnail(photo, size)
    local MAX_ATTEMPTS = 3

    for attempt = 1, MAX_ATTEMPTS do
        local jpegData, thumbError, done = nil, nil, false

        photo:requestJpegThumbnail(size, size, function(data, errorMsg)
            if data and #data > 0 then jpegData = data
            else thumbError = errorMsg or 'unknown' end
            done = true
        end)

        local deadline = os.time() + 30
        while not done do
            LrTasks.yield()
            if os.time() > deadline then
                return nil, 'Timed out waiting for preview. Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.'
            end
        end

        if jpegData then
            -- Size guard — Anthropic rejects images over 10 MB
            if #jpegData > MAX_IMAGE_BYTES then
                return nil, string.format(
                    'Preview is too large to send (%.1f MB — limit is 9 MB). ' ..
                    'Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.',
                    #jpegData / (1024 * 1024))
            end
            -- Dimension guard
            local w, h = getJpegDimensions(jpegData)
            if w and h and (w > MAX_IMAGE_DIM or h > MAX_IMAGE_DIM) then
                return nil, string.format(
                    'Preview is too large (%d\195\151%d px — Anthropic limit is 8000 px). ' ..
                    'Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews, ' ..
                    'then retry. Or reduce the Preview Size in Skin Tone Optimizer Settings.',
                    w, h)
            end
            return jpegData, nil
        end

        LrTasks.yield()  -- brief yield before next attempt
    end

    return nil, 'Preview appears stale. Click a different photo and then ' ..
        're-select this one to reset the preview, then run Optimise again. ' ..
        'Or go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews.'
end

-- ─────────────────────────────────────────────────────────
-- Read the current White Balance + HSL settings
-- Returns a flat table of the relevant keys
-- ─────────────────────────────────────────────────────────
local HSL_COLORS = { 'Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta' }

local function readCurrentSettings(photo)
    local ds = photo:getDevelopSettings()
    if not ds then return {} end

    local s = {}

    -- White Balance
    s.WhiteBalance  = ds.WhiteBalance  or 'Custom'
    s.Temperature   = ds.Temperature   or 5500
    s.Tint          = ds.Tint          or 0

    -- HSL Color Mixer (24 sliders)
    for _, color in ipairs(HSL_COLORS) do
        s['HueAdjustment'        .. color] = ds['HueAdjustment'        .. color] or 0
        s['SaturationAdjustment' .. color] = ds['SaturationAdjustment' .. color] or 0
        s['LuminanceAdjustment'  .. color] = ds['LuminanceAdjustment'  .. color] or 0
    end

    return s
end

-- ─────────────────────────────────────────────────────────
-- Build a readable summary of current settings for the prompt
-- ─────────────────────────────────────────────────────────
local function settingsSummary(s)
    local lines = {
        string.format('White Balance: %s  Temperature: %dK  Tint: %+d',
            s.WhiteBalance or 'Custom',
            s.Temperature  or 5500,
            s.Tint         or 0),
        '',
        'HSL Color Mixer (current values):',
        string.format('  Color    | Hue | Saturation | Luminance'),
        string.format('  ---------|-----|------------|----------'),
    }
    for _, color in ipairs(HSL_COLORS) do
        lines[#lines + 1] = string.format(
            '  %-8s | %+4d | %+5d      | %+5d',
            color,
            s['HueAdjustment'        .. color] or 0,
            s['SaturationAdjustment' .. color] or 0,
            s['LuminanceAdjustment'  .. color] or 0
        )
    end
    return table.concat(lines, '\n')
end

-- ─────────────────────────────────────────────────────────
-- Anthropic API call
-- ─────────────────────────────────────────────────────────
local SYSTEM_PROMPT = [[You are an expert colour grading specialist and portrait photographer with deep knowledge of skin tone rendering in digital photography.

Your task is to analyse a portrait photo and recommend precise Lightroom Classic White Balance and HSL Color Mixer adjustments to achieve natural, flattering skin tones. You have access to both the image and the photo's current develop settings.

Guidelines:
- Prioritise warmth and flattery over clinical accuracy
- Adjust the Red, Orange, and Yellow channels most heavily (these contain skin tone information)
- Keep non-skin colours (Aqua, Blue, Green) conservative — only adjust if they clash with or contaminate skin tones
- White Balance should complement the scene's natural light; avoid over-warming or over-cooling
- All HSL values must be integers in the range -100 to +100
- Temperature must be an integer in the range 2000 to 50000
- Tint must be an integer in the range -150 to +150]]

local function buildUserPrompt(settingsText)
    return string.format([[Analyse this portrait photo and the current Lightroom develop settings shown below. Recommend optimised White Balance and HSL Color Mixer adjustments to produce natural, flattering skin tones.

CURRENT LIGHTROOM SETTINGS:
%s

Respond with ONLY valid JSON — no markdown, no code fences, no extra text. Use exactly this structure:
{
  "has_skin": true,
  "temperature": 5600,
  "tint": 5,
  "hue": {
    "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0,
    "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0
  },
  "saturation": {
    "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0,
    "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0
  },
  "luminance": {
    "Red": 0, "Orange": 0, "Yellow": 0, "Green": 0,
    "Aqua": 0, "Blue": 0, "Purple": 0, "Magenta": 0
  },
  "reasoning": "2-3 sentences explaining what you saw in the skin tones and why you made these specific adjustments"
}

Rules:
- Set has_skin to false (and return zeroed adjustments) if no human skin is visible in the image
- All hue/saturation/luminance values must be integers between -100 and +100
- temperature must be an integer between 2000 and 50000
- tint must be an integer between -150 and +150
- reasoning must be concise (2-3 sentences max)]], settingsText)
end

local function callClaudeAPI(jpegData, currentSettings, apiKey, model)
    local b64 = base64Encode(jpegData)

    local settingsText = settingsSummary(currentSettings)
    local userPrompt   = buildUserPrompt(settingsText)

    local requestBody = json.encode({
        model      = model,
        max_tokens = 2048,
        system     = SYSTEM_PROMPT,
        messages   = {
            {
                role    = 'user',
                content = {
                    {
                        type   = 'image',
                        source = {
                            type       = 'base64',
                            media_type = 'image/jpeg',
                            data       = b64,
                        },
                    },
                    {
                        type = 'text',
                        text = userPrompt,
                    },
                },
            },
        },
    })

    -- All headers explicitly in the array — do NOT pass mimeType as a 4th
    -- argument: in some LR Classic versions it doesn't set Content-Type,
    -- causing Cloudflare to reject the request with an HTML 400.
    local headers = {
        { field = 'Content-Type',      value = 'application/json' },
        { field = 'x-api-key',         value = apiKey             },
        { field = 'anthropic-version', value = '2023-06-01'       },
    }

    local responseBody, responseHeaders = LrHttp.post(
        'https://api.anthropic.com/v1/messages',
        requestBody,
        headers
    )

    if not responseBody then
        return nil, 'Network error: no response received from Anthropic'
    end

    if responseHeaders and responseHeaders.status ~= 200 then
        local detail  = ''
        local errData = json.decode(responseBody)
        if errData and errData.error then
            detail = '\n' .. (errData.error.message or errData.error.type or '')
        elseif responseBody and #responseBody > 0 then
            detail = '\nRaw response: ' .. responseBody:sub(1, 500)
        end
        return nil, ('API error ' .. tostring(responseHeaders.status) .. detail)
    end

    local apiResp = json.decode(responseBody)
    if not apiResp then
        return nil, 'Could not parse API response as JSON'
    end

    if not (apiResp.content and apiResp.content[1] and apiResp.content[1].text) then
        return nil, 'Unexpected API response structure'
    end

    local claudeText = apiResp.content[1].text

    -- Strip markdown code fences if Claude added them despite instructions
    claudeText = claudeText:match('```json%s*(.-)%s*```')
              or claudeText:match('```%s*(.-)%s*```')
              or claudeText
    claudeText = claudeText:match('^%s*(.-)%s*$')

    -- Strip leading '+' from positive numbers: Claude sometimes writes +4 which
    -- is not valid JSON (the spec only allows an optional leading minus).
    -- Replace any '+' that immediately follows a JSON value delimiter
    -- (colon, comma, or opening bracket, with optional whitespace).
    claudeText = claudeText:gsub('([:%[,]%s*)%+(%d)', '%1%2')

    -- Fallback: extract outermost { ... } in case Claude prepended/appended prose
    local result = json.decode(claudeText)
    if not result then
        -- Find the first '{' and the last '}' and try that substring
        local jsonStart = claudeText:find('{', 1, true)
        local jsonEnd   = claudeText:match('.*()%}')  -- last '}' position
        if jsonStart and jsonEnd and jsonEnd >= jsonStart then
            result = json.decode(claudeText:sub(jsonStart, jsonEnd))
        end
    end
    if not result then
        -- Surface the raw text so the user (and developer) can see what Claude said
        local preview = claudeText:sub(1, 400)
        return nil, 'Could not parse skin tone JSON from Claude response.\nRaw text: ' .. preview
    end

    -- Basic validation
    if type(result.has_skin)    ~= 'boolean' then return nil, 'Missing "has_skin" in response'    end
    if type(result.temperature) ~= 'number'  then return nil, 'Missing "temperature" in response' end
    if type(result.tint)        ~= 'number'  then return nil, 'Missing "tint" in response'        end
    if type(result.hue)         ~= 'table'   then return nil, 'Missing "hue" table in response'   end
    if type(result.saturation)  ~= 'table'   then return nil, 'Missing "saturation" table'        end
    if type(result.luminance)   ~= 'table'   then return nil, 'Missing "luminance" table'         end

    return result, nil
end

-- ─────────────────────────────────────────────────────────
-- Clamp a value to an integer within [lo, hi]
-- ─────────────────────────────────────────────────────────
local function clampInt(v, lo, hi)
    v = tonumber(v) or 0
    v = math.floor(v + 0.5)
    if v < lo then v = lo end
    if v > hi then v = hi end
    return v
end

-- ─────────────────────────────────────────────────────────
-- Apply White Balance + HSL settings to the photo
--
-- IMPORTANT: No pcall — Lua 5.1 forbids yielding inside pcall,
-- and catalog functions yield internally.  Use a boolean flag
-- set at the end of the write callback instead.
-- ─────────────────────────────────────────────────────────
local function applySettings(catalog, photo, result)
    local newSettings = {}

    -- White Balance
    newSettings.WhiteBalance = 'Custom'
    newSettings.Temperature  = clampInt(result.temperature, 2000, 50000)
    newSettings.Tint         = clampInt(result.tint,        -150, 150)

    -- HSL Color Mixer (24 sliders)
    for _, color in ipairs(HSL_COLORS) do
        newSettings['HueAdjustment'        .. color] =
            clampInt(result.hue        and result.hue[color],        -100, 100)
        newSettings['SaturationAdjustment' .. color] =
            clampInt(result.saturation and result.saturation[color], -100, 100)
        newSettings['LuminanceAdjustment'  .. color] =
            clampInt(result.luminance  and result.luminance[color],  -100, 100)
    end

    -- Write transaction — no yielding inside here
    local writeOk = false
    catalog:withWriteAccessDo('Claude AI: Skin Tone Optimizer', function()
        photo:applyDevelopSettings(newSettings)
        writeOk = true
    end)

    return writeOk, newSettings
end

-- ─────────────────────────────────────────────────────────
-- Build a human-readable changes summary for the result dialog
-- ─────────────────────────────────────────────────────────
local function buildSummary(oldSettings, newSettings, result)
    local lines = {}

    -- White Balance changes
    local tempOld = oldSettings.Temperature or 5500
    local tintOld = oldSettings.Tint        or 0
    local tempNew = newSettings.Temperature
    local tintNew = newSettings.Tint

    lines[#lines + 1] = 'WHITE BALANCE'
    lines[#lines + 1] = string.format(
        '  Temperature: %dK → %dK  (%+d)',
        tempOld, tempNew, tempNew - tempOld)
    lines[#lines + 1] = string.format(
        '  Tint:        %+d → %+d  (%+d)',
        tintOld, tintNew, tintNew - tintOld)

    -- HSL changes — only list colours that actually changed
    local hslLines = {}
    for _, color in ipairs(HSL_COLORS) do
        local hOld = oldSettings['HueAdjustment'        .. color] or 0
        local sOld = oldSettings['SaturationAdjustment' .. color] or 0
        local lOld = oldSettings['LuminanceAdjustment'  .. color] or 0
        local hNew = newSettings['HueAdjustment'        .. color] or 0
        local sNew = newSettings['SaturationAdjustment' .. color] or 0
        local lNew = newSettings['LuminanceAdjustment'  .. color] or 0

        if hOld ~= hNew or sOld ~= sNew or lOld ~= lNew then
            hslLines[#hslLines + 1] = string.format(
                '  %-8s  H:%+d→%+d  S:%+d→%+d  L:%+d→%+d',
                color,
                hOld, hNew, sOld, sNew, lOld, lNew
            )
        end
    end

    if #hslLines > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'HSL COLOR MIXER (changed channels only)'
        for _, l in ipairs(hslLines) do
            lines[#lines + 1] = l
        end
    else
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'HSL COLOR MIXER: no changes'
    end

    -- Claude's reasoning
    if type(result.reasoning) == 'string' and #result.reasoning > 0 then
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'CLAUDE\'S REASONING'
        lines[#lines + 1] = result.reasoning
    end

    return table.concat(lines, '\n')
end

-- ─────────────────────────────────────────────────────────
-- Entry point (runs when user clicks the menu item)
-- ─────────────────────────────────────────────────────────
LrTasks.startAsyncTask(function()

    -- Check API key
    local apiKey = pluginPrefs.claudeApiKey
    if not apiKey or LrStringUtils.trimWhitespace(apiKey) == '' then
        LrDialogs.message(
            'Claude AI Skin Tone Optimizer',
            'No API key found.\n\nGo to  Library \226\150\184 Plug-in Extras \226\150\184 Skin Tone Optimizer Settings  to enter your Anthropic API key.\n\nGet a key at: console.anthropic.com',
            'critical'
        )
        return
    end

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
        LrDialogs.message(
            'Claude AI Skin Tone Optimizer',
            'No photos selected. Select one or more photos in the Library grid and try again.',
            'info'
        )
        return
    end

    -- Read preferences (with defaults)
    local model      = pluginPrefs.claudeModel     or 'claude-opus-4-5'
    local thumbSize  = tonumber(pluginPrefs.thumbnailSize) or 1024
    local photoCount = #photos

    -- Confirmation dialog
    local confirmMsg = string.format(
        'Optimise skin tones for %d photo%s using Claude AI?\n\n' ..
        '\226\128\162 Adjusts White Balance (Temperature + Tint)\n' ..
        '\226\128\162 Adjusts HSL Color Mixer (all 8 colour channels \195\151 3 axes)\n' ..
        '\226\128\162 All other develop settings are left unchanged\n' ..
        '\226\128\162 Model: %s\n\n' ..
        'Use History in the Develop module to undo if needed.',
        photoCount,
        photoCount == 1 and '' or 's',
        model
    )

    local confirm = LrDialogs.confirm(
        'Claude AI Skin Tone Optimizer',
        confirmMsg,
        'Optimise',
        'Cancel'
    )
    if confirm ~= 'ok' then return end

    -- Process with progress bar
    LrFunctionContext.callWithContext('skinToneOptiProgress', function(context)

        local progress = LrProgressScope({
            title           = 'Claude AI: Optimising skin tones',
            functionContext = context,
        })

        local successCount = 0
        local skippedCount = 0
        local errors       = {}
        local summaries    = {}   -- collect per-photo summaries for the result dialog

        for i, photo in ipairs(photos) do

            if progress:isCanceled() then break end

            local fileName = photo:getFormattedMetadata('fileName') or ('photo ' .. i)
            progress:setPortionComplete(i - 1, photoCount)
            progress:setCaption(string.format('%s  (%d / %d)', fileName, i, photoCount))
            LrTasks.yield()

            -- Step 1: Read current settings (outside write access — may yield)
            local currentSettings = readCurrentSettings(photo)

            -- Step 2: Get thumbnail
            local jpegData, thumbErr = getPhotoThumbnail(photo, thumbSize)
            if not jpegData then
                errors[#errors + 1] = string.format(
                    '%-40s  preview error: %s', fileName, thumbErr or '?')
            else
                -- Step 3: Call Claude
                local result, apiErr = callClaudeAPI(
                    jpegData, currentSettings, apiKey, model)

                if not result then
                    errors[#errors + 1] = string.format(
                        '%-40s  API error: %s', fileName, apiErr or '?')
                elseif not result.has_skin then
                    -- No skin found — skip without error
                    skippedCount = skippedCount + 1
                    summaries[#summaries + 1] = {
                        fileName = fileName,
                        skipped  = true,
                        reason   = result.reasoning or 'No human skin detected in this image.',
                    }
                else
                    -- Step 4: Apply settings (no pcall — catalog ops yield internally)
                    local written, newSettings = applySettings(catalog, photo, result)
                    if written then
                        successCount = successCount + 1
                        summaries[#summaries + 1] = {
                            fileName    = fileName,
                            skipped     = false,
                            summary     = buildSummary(currentSettings, newSettings, result),
                        }
                    else
                        errors[#errors + 1] = string.format(
                            '%-40s  write failed', fileName)
                    end
                end
            end

            -- Brief pause between photos to stay within API rate limits
            if i < photoCount and not progress:isCanceled() then
                LrTasks.sleep(0.3)
            end
        end

        progress:done()

        -- ── Results dialog ──────────────────────────────────────────
        local resultTitle = 'Claude AI Skin Tone Optimizer \226\128\148 Done'

        if #errors == 0 and #summaries == 0 then
            -- Nothing processed
            LrDialogs.message(resultTitle,
                'No photos were processed.', 'warning')
            return
        end

        -- Build the full result message
        local msgParts = {}

        -- Stats line
        local statLine
        if skippedCount == 0 then
            statLine = string.format(
                '%d of %d photo%s optimised successfully.',
                successCount, photoCount,
                photoCount == 1 and '' or 's')
        else
            statLine = string.format(
                '%d optimised, %d skipped (no skin detected), %d error%s.',
                successCount, skippedCount,
                #errors, #errors == 1 and '' or 's')
        end
        msgParts[#msgParts + 1] = statLine

        -- Per-photo summaries
        for _, s in ipairs(summaries) do
            msgParts[#msgParts + 1] = '\n\226\148\128\226\148\128\226\148\128 ' .. s.fileName .. ' \226\148\128\226\148\128\226\148\128'
            if s.skipped then
                msgParts[#msgParts + 1] = 'Skipped: ' .. (s.reason or 'No skin detected.')
            else
                msgParts[#msgParts + 1] = s.summary
            end
        end

        -- Errors (if any)
        if #errors > 0 then
            msgParts[#msgParts + 1] = '\nFailed (' .. #errors .. '):'
            msgParts[#msgParts + 1] = table.concat(errors, '\n')
        end

        local msgType = (#errors > 0) and 'warning' or 'info'
        LrDialogs.message(resultTitle, table.concat(msgParts, '\n'), msgType)

    end)  -- callWithContext

end)  -- startAsyncTask
