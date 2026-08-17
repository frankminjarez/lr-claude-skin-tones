# Claude AI Skin Tone Optimizer — Lightroom Classic Plugin

Automatically adjusts **White Balance** and the **HSL Color Mixer** on selected photos to produce natural, flattering skin tones, using Anthropic's Claude vision models. All other develop settings are left untouched.

---

## How it works

For each selected photo the plugin:

1. Reads the photo's current White Balance and HSL Color Mixer values from Lightroom
2. Fetches a JPEG preview from Lightroom's cache
3. Sends both the image and the current settings to Claude via the Anthropic API
4. Claude analyses the skin tones and returns recommended adjustments
5. Lightroom writes the new values — Temperature, Tint, and all 24 HSL sliders (8 colours × Hue / Saturation / Luminance)
6. A summary dialog shows exactly what changed and Claude's reasoning

---

## Requirements

| Item | Minimum |
|------|---------|
| Lightroom Classic | 6.0 / CC 2015 or newer |
| Operating system | macOS or Windows |
| Anthropic account | API key from [console.anthropic.com](https://console.anthropic.com) |
| Internet access | Required at generation time |

---

## Installation

1. **Download** the latest `SkinToneOptimizer-vX.X.zip` from the [Releases](../../releases) page and unzip it. You should end up with a folder named `SkinToneOptimizer.lrplugin`.

2. In Lightroom Classic, go to **File → Plug-in Manager…**

3. Click **Add** (bottom-left), navigate to the `SkinToneOptimizer.lrplugin` folder, select it, and click **Add Plug-in**.

4. The plugin should appear in the list with status **Installed and running**. Click **Done**.

> **Reinstalling or updating?** Always remove the old plugin first (select it → Remove), quit Lightroom completely, delete the old plugin folder, then reinstall fresh. Lightroom caches plugin state and a simple file overwrite may not take effect.

---

## Setup

1. Go to **File → Plug-in Extras → Skin Tone Optimizer Settings…**

2. Paste your **Anthropic API key** (starts with `sk-ant-`). Get one at [console.anthropic.com](https://console.anthropic.com).

3. Choose a **model**:

| Model | Characteristic |
|-------|---------------|
| `claude-opus-4-5` | Best colour analysis — recommended for portraits |
| `claude-sonnet-4-5` | Faster, lower cost per image |
| `claude-haiku-4-5` | Fastest, cheapest — good for bulk preview runs |

4. Set the **Preview size** (see [Settings reference](#settings-reference) below).

5. Click **Save**.

---

## Usage

1. In the **Library** or **Develop** module, select one or more photos containing human subjects.

2. Go to **File → Plug-in Extras → Optimize Skin Tones with Claude AI**.

3. Review the confirmation dialog and click **Optimise**.

4. A progress bar appears while each photo is processed.

5. When complete, a summary dialog shows the before → after values for every changed parameter and Claude's reasoning. Use **Develop → History** to undo if you prefer the original.

---

## What gets adjusted

| Lightroom field | Range | Notes |
|-----------------|-------|-------|
| White Balance | Custom | Forces Custom mode |
| Temperature | 2000 – 50 000 K | Warm/cool balance |
| Tint | −150 to +150 | Green/magenta balance |
| Hue — Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta | −100 to +100 | Colour shift per channel |
| Saturation — same 8 channels | −100 to +100 | Colour intensity per channel |
| Luminance — same 8 channels | −100 to +100 | Brightness per channel |

**Nothing else is touched.** Exposure, tone curve, sharpening, noise reduction, lens corrections, and all other panels are left exactly as they were.

---

## Settings reference

### Model

Controls the Claude model used for analysis. `claude-opus-4-5` gives the most nuanced colour reasoning; `claude-haiku-4-5` is significantly cheaper for bulk runs where speed matters more than precision.

### Preview size

The longest edge (in pixels) of the JPEG preview sent to Claude. Higher values give Claude more detail to work with but increase API payload and cost.

| Size | Typical use |
|------|-------------|
| 512 px | Fast preview, bulk runs |
| 768 px | Good balance for most portraits |
| **1024 px** | **Recommended default** |
| 1536 px | Complex lighting, detailed skin texture |
| 2048 px | Maximum detail — slowest, highest cost |

> **Important:** Lightroom sometimes returns a full-resolution cached preview regardless of the requested size. If you see an error about the image exceeding 8000 pixels, go to **Library → Previews → Build Standard-Sized Previews** so Lightroom has a properly-sized preview available, then retry.

---

## Tips for best results

- **Select photos with clearly visible human skin.** The plugin detects whether skin is present and skips photos where none is found rather than applying random adjustments.

- **Build standard-sized previews first** for any photo that shows a preview-size error. Go to **Library → Previews → Build Standard-Sized Previews**.

- **RAW files** (ARW, CR3, NEF, etc.) are analysed via their JPEG preview, not the raw sensor data. Make sure the preview reflects your current crop and basic develop adjustments.

- **Run on one photo first** before processing a large batch, so you can evaluate the style of Claude's adjustments and choose the right model for your workflow.

- **Use History to compare.** After the plugin runs, click on the state just before the plugin's entry in the Develop module History panel to A/B compare the before and after.

- **Batch runs** add a 0.3-second pause between photos to stay within Anthropic's rate limits. A batch of 50 photos will take roughly 2–5 minutes depending on the model and API response time.

---

## No-skin detection

If Claude determines that no human skin is visible in a photo, the photo is skipped without error and noted in the summary as "No human skin detected." This prevents the plugin from misapplying skin-tone adjustments to landscapes, product shots, or other non-portrait images.

---

## API cost (approximate)

Anthropic charges per token. A typical 1024 px image call costs roughly:

| Model | Approx. cost per photo |
|-------|------------------------|
| claude-opus-4-5 | ~$0.02 – $0.05 |
| claude-sonnet-4-5 | ~$0.003 – $0.008 |
| claude-haiku-4-5 | ~$0.001 – $0.003 |

Monitor your usage at [console.anthropic.com/usage](https://console.anthropic.com/usage).

---

## Troubleshooting

**Plugin does not appear in File → Plug-in Extras**
→ Make sure the folder is named exactly `SkinToneOptimizer.lrplugin` and that Lightroom shows it as "Installed and running" in the Plug-in Manager. If you recently updated the plugin, do a full remove → quit Lightroom → delete old folder → reinstall.

**"No preview available / Timed out waiting for preview"**
→ Build previews first: **Library → Previews → Build Standard-Sized Previews**.

**"Preview is too large (NNNN × NNNN px)"**
→ Lightroom returned a full-res cached preview. Build Standard-Sized Previews as above, then retry.

**"API error 401"**
→ Your API key is invalid or revoked. Check it in **Skin Tone Optimizer Settings…**

**"API error 429"**
→ You've hit Anthropic's rate limit. Wait a minute and try again, or process a smaller batch.

**"Could not parse skin tone JSON"**
→ Claude returned an unexpected response format. Re-running the photo usually fixes it. If it persists, the raw response text is shown in the error — check whether the API key has access to the selected model.

**Settings are not saved after clicking Save**
→ Make sure the API key field is not empty and the Preview size is a number between 256 and 4096.

---

## License

MIT License — free to use, modify, and distribute.
