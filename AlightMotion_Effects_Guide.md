# Alight Motion Custom Effects Authoring Guide (Complete AI Reference)

This document is a complete technical reference for authoring custom **Alight Motion** effects (`.xml` with embedded GLSL fragment/vertex shaders and/or JavaScript transform scripts) targeting Alight Motion iOS (v6.2.60+, Metal/GLSL pipeline). Give this file (optionally alongside `AlightMotion_All_Effects.md`) to an AI so it can generate valid, ready-to-import effects on the first try.

---

## 1. How Custom Effects Load in Modded Alight Motion

- Custom effects are stored as `.xml` files in the app's `Documents/CustomEffects/` directory and injected into `BuiltinEffects` at launch.
- Each custom effect MUST have:
  - A unique `id` prefixed with `com.alightcreative.effects.custom_<slug>` (the importer enforces this automatically if omitted or colliding).
  - `compat="acScreenNorm-y"` on `<effect>` so `acScreenNorm` uses Alight Motion's standard Y orientation.
  - A `category` slug matching either `"custom"`, a user-created category slug, or a built-in category slug (`color`, `drawing`, `blur`, `distort`, `procedural`, `3d`, `transform`, `repeat`, `matte`, `opacity`, `text`, `other`).
  - A valid `thumb` attribute (e.g., `thumb="thumb/copy-bg.webp"` — custom PNG thumbnails are overlaid separately by the importer).
  - **Do NOT** set `internal="true"`, `deprecated="true"`, or `experimental="true"`, or the effect will be hidden from the picker.
- **Restart required**: Alight Motion parses `BuiltinEffects/*.xml` and `EffectCategory.all` once on startup. After creating or deleting a custom effect or category, restart Alight Motion to load changes.

---

## 2. Root `<effect>` XML Schema

```xml
<?xml version='1.0' encoding='UTF-8' ?>
<effect
    id="com.alightcreative.effects.custom_my_effect"
    compat="acScreenNorm-y"
    name="My Effect"
    desc="Short description of what the effect does."
    category="custom"
    tags="custom,glow"
    thumb="thumb/copy-bg.webp"
    overdraw="false"
    maxOverdraw="0.0">

    <params>
        <!-- Parameter and texture declarations -->
    </params>

    <!-- Optional: multi-pass rendering -->
    <passes>
        <pass target="buf1" blend="overwrite" />
        <pass />
    </passes>

    <!-- Shader (GLSL ES fragment, and optionally vertex) -->
    <shader type="fragment" precision="high"><![CDATA[
        void main() {
            ...
        }
    ]]></shader>

    <!-- Optional: JavaScript transform/property script -->
    <!--
    <script lang="js"><![CDATA[
        function animate(env, el, p) { ... }
    ]]></script>
    -->
</effect>
```

### Root `<effect>` Attributes

| Attribute | Required | Values / Notes |
|---|---|---|
| `id` | Yes | Globally unique reverse-DNS ID, e.g. `com.alightcreative.effects.custom_bloom`. |
| `compat` | Recommended | `"acScreenNorm-y"` — standardizes `acScreenNorm` vertical axis. Always include for shaders. |
| `name` | Yes | Plain display name string (e.g. `"Chromatic Aberration"`). |
| `desc` | Recommended | Plain description shown in the effect info panel. |
| `category` | Yes | Category slug (`custom`, `color`, `drawing`, `blur`, `distort`, `procedural`, `3d`, `transform`, `repeat`, `matte`, `opacity`, `text`, `other`, or any user-created category slug). |
| `tags` | Optional | Comma-separated search keywords, e.g. `"custom,color,glow"`. |
| `thumb` | Recommended | Built-in WebP path such as `"thumb/copy-bg.webp"`. |
| `overdraw` | Optional | `"true"` or `"false"`. Set `"true"` when the effect draws outside the layer's original bounding box (blurs, glows, drop shadows, displacements). |
| `maxOverdraw` | Optional | Float fraction of screen/layer size (e.g. `"0.1"` or `"0.25"`) controlling extra render padding when `overdraw="true"`. |
| `auto-transform` | Optional | `"true"` for JS `<script>` effects that animate layer transform properties. |
| `affinity` | Optional | Restricts layer types: `"media"`, `"text!"`, `"transform-animation!"`, `"stroke!"`, `"freehand!"`, `"animation!"`. Omit for general layer support. |
| `type` | Optional | `"text"` or `"drawing"` for specialized pipelines. Omit for standard shader/transform effects. |

---

## 3. `<params>` Reference (All Supported Controls & Textures)

Every `<params>` child with an `id` becomes a **uniform** with that exact identifier in GLSL shaders and a property on `p.<id>` in JS scripts. All numeric/color/point parameters are automatically keyframeable by Alight Motion.

### 3.1 `<texture>` (Image / Buffer Inputs)
```xml
<texture id="inputImg" srcType="content" />
<texture id="bgImg" srcType="comp" />
<texture id="tempBuf" srcType="buffer" downsample="2" />
```
- `srcType="content"`: The current layer's rendered image (with prior effects applied). **Required** for almost all fragment shader effects.
- `srcType="comp"`: The composite background behind the current layer (useful for glass/refraction/blending effects like Copy Background).
- `srcType="buffer"`: An offscreen intermediate render target used with `<passes>`. Optional `downsample="2"` (or `"4"`) renders at 1/2 or 1/4 resolution for fast blurs/glows.
- In GLSL, a `<texture id="inputImg" .../>` is exposed as an `AC_ImageInfo` struct:
  - `inputImg.texture` — sampler2D to pass to `texture2DCv(inputImg.texture, uv)` or `texture2D(inputImg.texture, uv)`.

### 3.2 `<spinner>` (Precision Numeric Dial — Most Common)
```xml
<spinner id="strength" default="0.5" min="0.0" max="2.0" step="0.01" label="Strength" type="percent" />
```
- **GLSL type**: `float`
- **Attributes**:
  - `id` (required), `label` (display name), `default`, `min`, `max`, `step`
  - `type` (optional unit formatting): `"percent"`, `"angle"` (degrees), `"hz"`, `"relative-percent"`, `"seconds"`, `"kelvin"`, `"angle-range"`, `"rpm"`
  - `logscale` (optional float, e.g. `"1.5"` for logarithmic response)
  - `snap` (optional), `ticks` (optional), `multiplier` (optional), `originValue` (optional), `enabled` (optional `"true"`/`"false"`, toggled by a `<switch enableTargets="...">`)

### 3.3 `<slider>` (Horizontal Slider)
```xml
<slider id="samples" default="16" min="4" max="64" step="1" label="Quality" type="integer" />
```
- **GLSL type**: `float` (even when `type="integer"`, treat as `float` in GLSL!)
- **Attributes**: `id`, `label`, `default`, `min`, `max`, `step`, `type` (`"integer"` or `"percent"`), `logscale`, `snap`, `ticks`, `enabled`.

### 3.4 `<switch>` (Boolean Toggle)
```xml
<switch id="invert" default="false" label="Invert" enableTargets="tintColor,tintAmount" />
```
- **GLSL type**: `bool` (or `float` > 0.5; use `if (invert)` in GLSL)
- **Attributes**: `id`, `label`, `default` (`"true"` or `"false"`), `enableTargets` (comma-separated param IDs enabled when switch is on), `enabled`.

### 3.5 `<color>` (RGBA Color Picker)
```xml
<color id="tint" default="#FF4080FF" label="Tint Color" alpha="true" />
```
- **GLSL type**: `vec4` (normalized `0.0..1.0` RGBA)
- **Attributes**: `id`, `label`, `default` (`#RRGGBB` or `#RRGGBBAA` hex), `alpha` (`"true"`/`"false"`), `enabled`.

### 3.6 `<selector>` (Dropdown or Radio Buttons)
```xml
<selector id="mode" style="dropdown" default="0" label="Blend Mode">
    <choice label="Normal" value="0" />
    <choice label="Multiply" value="1" />
    <choice label="Screen" value="2" />
    <choice label="Add" value="3" />
</selector>
```
- **GLSL type**: `int` (compare with `mode == 0`, `mode == 1`, etc.)
- **Attributes**: `id`, `label`, `default`, `style` (`"dropdown"` or `"radio"`), `enabled`.

### 3.7 `<point>` (2D Position Control)
```xml
<point id="center" default="0.0,0.0" min="-2.0,-2.0" max="2.0,2.0" step="0.01" label="Center" />
```
- **GLSL type**: `vec2`
- **Attributes**: `id`, `label`, `default` (`"x,y"`), `min`, `max`, `step`, `enabled`.

### 3.8 `<xyz>` (3D Vector / Rotation Control)
```xml
<xyz id="rot" type="rotate" default="0.0,0.0,0.0" step="0.5" label="Rotation" />
```
- **GLSL type**: `vec3`
- **Attributes**: `id`, `label`, `default` (`"x,y,z"`), `type` (`"rotate"`), `applyto`, `step`, `ticks`.

### 3.9 `<orient>`, `<hue-disc>`, `<float>`, `<section>`, `<tip>`
- `<orient id="orient" default="0" label="Orientation" />`: 2D/3D orientation control.
- `<hue-disc id="hue" default="0.0" bias="0.0" label="Hue" />`: circular hue picker (`float` degrees).
- `<float id="constVal" value="1.0" />`: hidden constant float uniform.
- `<section text="Glow Settings" />`: visual section header in the effect inspector.
- `<tip text="Increase overdraw if edges clip." />`: informational tip text in the inspector.

---

## 4. GLSL Shader Reference (Alight Motion Engine)

Alight Motion wraps your `<shader type="fragment" precision="high"><![CDATA[ ... ]]></shader>` body automatically with:
- Precision qualifiers
- All `<params>` uniform declarations
- All built-in `ac*` uniforms and `texture2DCv` helper functions

**CRITICAL**: Do **NOT** re-declare `<params>` uniforms or built-in `ac*` uniforms inside your `<shader>` block. Write helper functions and `void main() { ... }` directly.

### 4.1 Built-in Uniforms & Variables

| Identifier | Type | Description |
|---|---|---|
| `acScreenNorm` | `vec2` | Current fragment position in normalized screen coordinates `(0.0..1.0, 0.0..1.0)`. Primary UV for sampling `inputImg.texture` and `comp.texture`. |
| `acLayerNorm` | `vec2` | Current fragment position in normalized layer-local coordinates `(0.0..1.0, 0.0..1.0)` before layer transform. |
| `acScreenSize` | `vec2` | Render viewport resolution in pixels `(width, height)`. Use `1.0 / acScreenSize` for 1-pixel UV step! |
| `acLayerSize` | `vec2` | Layer size in pixels `(width, height)`. |
| `acLayerSizeNorm` | `vec2` | Layer size normalized to screen size. |
| `acLayerCenter` | `vec2` | Layer center in screen pixels. |
| `acLayerCenterNorm` | `vec2` | Layer center in normalized screen coordinates `(0.0..1.0)`. |
| `acLayerPivot` | `vec2` | Layer anchor/pivot point. |
| `acLayerToScreen` | `mat4` / `mat3` | Transform matrix from layer space to screen space. |
| `acScreenToLayer` | `mat4` / `mat3` | Inverse transform matrix from screen space to layer space. |
| `acPreviewSize` | `vec2` | Current preview canvas size in pixels. |
| `acTime` | `float` | Current playback time in seconds (useful for animated procedural effects). |
| `acPass` | `int` | Zero-based pass index (`0`, `1`, `2`, ...) when `<passes>` is declared. |
| `acShowGuides` | `bool` | Whether editor guides/overlays are visible. |
| `acVelocity` | `vec2` | Layer linear motion velocity (for motion blur / trails). |
| `acScaleVelocity` | `vec2` | Layer scale velocity. |
| `acAngularVelocity` | `float` | Layer angular velocity. |
| `gl_FragColor` | `vec4` | Output pixel color (premultiplied RGBA). |

### 4.2 Sampling Textures Safely

- **Always prefer `texture2DCv(inputImg.texture, uv)`** over raw `texture2D(...)`!
  - `texture2DCv` automatically handles Alight Motion's coordinate viewport / virtual canvas bounds and returns transparent black `vec4(0.0)` outside valid bounds instead of smearing edge pixels.
- **Premultiplied Alpha**: Alight Motion operates in **premultiplied alpha** space (`rgb` is already multiplied by `a`).
  - When modifying RGB (brightness, contrast, color grading, invert):
    ```glsl
    vec4 c = texture2DCv(inputImg.texture, acScreenNorm);
    vec3 rgb = (c.a > 0.0001) ? (c.rgb / c.a) : vec3(0.0);
    // ... modify unpremultiplied rgb ...
    rgb = clamp(rgb, 0.0, 1.0);
    gl_FragColor = vec4(rgb * c.a, c.a);
    ```
  - Failing to unpremultiply/repremultiply causes dark or glowing fringes on transparent edges!

### 4.3 Multi-Pass Rendering (`<passes>`)

Declare intermediate `<texture id="buf" srcType="buffer" />` in `<params>`, list passes in `<passes>`, and branch on `acPass` in `main()`:

```xml
<params>
    <texture id="inputImg" srcType="content" />
    <texture id="pass1" srcType="buffer" downsample="2" />
    <spinner id="radius" default="8.0" min="0.0" max="50.0" step="0.5" label="Radius" />
</params>
<passes>
    <pass target="pass1" blend="overwrite" />
    <pass />
</passes>
```
- Pass `0` (`acPass == 0`) renders into `pass1`.
- Pass `1` (`acPass == 1`, `<pass />` with no `target`) renders to the final layer output.
- Use `blend="overwrite"` on buffer passes so previous frame/pass data is replaced cleanly.

### 4.4 GLSL-to-Metal Compiler Rules (Avoid Compile Failures!)

Alight Motion on iOS compiles GLSL ES into Metal via SPIR-V/MSL translation. Follow these strict rules so shaders never fail to compile on iOS:
1. **No implicit int-to-float conversions**: Write `1.0`, `0.0`, `2.0`, `float(i)` — NEVER `vec3(1)` or `x * 2` when `x` is `float`.
2. **Constant loop bounds**: `for (int i = -8; i <= 8; i++)` is always safe. If the loop count is controlled by a parameter, use a fixed upper bound with `if (float(i) > count) break;`.
3. **No `precision` or `#version` lines inside `<shader>`**: Alight Motion injects the header itself.
4. **Avoid `pow(negative, y)`**: Always `pow(max(x, 0.0001), y)` — negative bases produce NaN in Metal.
5. **Avoid division by zero**: Guard denominators with `max(denom, 0.0001)`.
6. **Helper functions must be declared BEFORE `void main()`**.
7. **Always write to `gl_FragColor`** on every code path.

---

## 5. JavaScript Transform Effects (`<script lang="js">`)

For effects that animate layer position, rotation, scale, or opacity (instead of pixel shading), use `auto-transform="true"` and `<script lang="js">`:

```xml
<?xml version='1.0' encoding='UTF-8' ?>
<effect id="com.alightcreative.effects.custom_float" compat="acScreenNorm-y" name="Gentle Float" desc="Smoothly bobs the layer up and down." auto-transform="true" category="custom" tags="custom,transform,float" thumb="thumb/copy-bg.webp">
    <params>
        <spinner id="speed" default="1.5" min="0.1" max="10.0" step="0.1" label="Speed" type="hz" />
        <spinner id="amount" default="30.0" min="0.0" max="300.0" step="1.0" label="Amount" />
    </params>
    <script lang="js"><![CDATA[
        function animate(env, el, p) {
            var t = env.time;
            var dy = Math.sin(t * p.speed * Math.PI * 2.0) * p.amount;
            el.pos.y += dy;
        }
    ]]></script>
</effect>
```
Common `animate(env, el, p)` fields:
- `env.time`: current time in seconds
- `el.pos.x`, `el.pos.y`: layer position offset in pixels
- `el.rot`: layer rotation in degrees
- `el.scale.x`, `el.scale.y`: layer scale multipliers
- `el.opacity`: layer opacity (`0.0..1.0`)
- `p.<paramId>`: evaluated keyframed value of any `<params>` control

---

## 6. Copy-Pasteable Templates

### Template A: Color / Shader Effect (Unpremultiplied Safe)
```xml
<?xml version='1.0' encoding='UTF-8' ?>
<effect id="com.alightcreative.effects.custom_duotone" compat="acScreenNorm-y" name="Duotone Tint" desc="Maps layer luminance between shadow and highlight colors." category="custom" tags="custom,color,duotone" thumb="thumb/copy-bg.webp">
    <params>
        <texture id="inputImg" srcType="content" />
        <color id="shadowCol" default="#120B2EFF" label="Shadows" alpha="false" />
        <color id="highCol" default="#34D399FF" label="Highlights" alpha="false" />
        <spinner id="mixAmt" default="1.0" min="0.0" max="1.0" step="0.01" label="Mix" type="percent" />
    </params>
    <shader type="fragment" precision="high"><![CDATA[
        void main() {
            vec4 c = texture2DCv(inputImg.texture, acScreenNorm);
            vec3 rgb = (c.a > 0.0001) ? (c.rgb / c.a) : vec3(0.0);
            float lum = dot(rgb, vec3(0.299, 0.587, 0.114));
            vec3 duo = mix(shadowCol.rgb, highCol.rgb, clamp(lum, 0.0, 1.0));
            vec3 outRgb = mix(rgb, duo, mixAmt);
            gl_FragColor = vec4(outRgb * c.a, c.a);
        }
    ]]></shader>
</effect>
```

### Template B: UV Distortion / Chromatic Split Effect
```xml
<?xml version='1.0' encoding='UTF-8' ?>
<effect id="com.alightcreative.effects.custom_rgb_split" compat="acScreenNorm-y" name="RGB Split" desc="Separates red, green, and blue channels along an angle." category="custom" tags="custom,distort,rgb,glitch" thumb="thumb/copy-bg.webp" overdraw="true" maxOverdraw="0.1">
    <params>
        <texture id="inputImg" srcType="content" />
        <spinner id="amount" default="12.0" min="0.0" max="100.0" step="0.5" label="Offset (px)" />
        <spinner id="angle" default="0.0" min="-360.0" max="360.0" step="1.0" label="Angle" type="angle" />
    </params>
    <shader type="fragment" precision="high"><![CDATA[
        void main() {
            float rad = radians(angle);
            vec2 dir = vec2(cos(rad), sin(rad)) * (amount / max(acScreenSize, vec2(1.0)));
            vec4 r = texture2DCv(inputImg.texture, acScreenNorm + dir);
            vec4 g = texture2DCv(inputImg.texture, acScreenNorm);
            vec4 b = texture2DCv(inputImg.texture, acScreenNorm - dir);
            float a = max(max(r.a, g.a), b.a);
            gl_FragColor = vec4(r.r, g.g, b.b, a);
        }
    ]]></shader>
</effect>
```

### Template C: Multi-Pass Separable Blur / Bloom
```xml
<?xml version='1.0' encoding='UTF-8' ?>
<effect id="com.alightcreative.effects.custom_soft_bloom" compat="acScreenNorm-y" name="Soft Bloom" desc="Two-pass thresholded glow blended over the layer." category="custom" tags="custom,glow,bloom" thumb="thumb/copy-bg.webp" overdraw="true" maxOverdraw="0.15">
    <params>
        <texture id="inputImg" srcType="content" />
        <texture id="hBuf" srcType="buffer" downsample="2" />
        <spinner id="threshold" default="0.6" min="0.0" max="1.0" step="0.01" label="Threshold" type="percent" />
        <spinner id="radius" default="16.0" min="0.0" max="60.0" step="0.5" label="Radius" />
        <spinner id="intensity" default="0.8" min="0.0" max="2.0" step="0.02" label="Intensity" type="percent" />
    </params>
    <passes>
        <pass target="hBuf" blend="overwrite" />
        <pass />
    </passes>
    <shader type="fragment" precision="high"><![CDATA[
        vec4 brightPass(vec2 uv) {
            vec4 c = texture2DCv(inputImg.texture, uv);
            float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
            float w = smoothstep(threshold, min(threshold + 0.25, 1.0), l);
            return c * w;
        }
        void main() {
            vec2 texel = (radius / 8.0) / max(acScreenSize, vec2(1.0));
            if (acPass == 0) {
                vec4 sum = vec4(0.0);
                float total = 0.0;
                for (int i = -6; i <= 6; i++) {
                    float fi = float(i);
                    float w = exp(-(fi * fi) / 18.0);
                    sum += brightPass(acScreenNorm + vec2(fi * texel.x, 0.0)) * w;
                    total += w;
                }
                gl_FragColor = sum / max(total, 0.0001);
            } else {
                vec4 base = texture2DCv(inputImg.texture, acScreenNorm);
                vec4 sum = vec4(0.0);
                float total = 0.0;
                for (int i = -6; i <= 6; i++) {
                    float fi = float(i);
                    float w = exp(-(fi * fi) / 18.0);
                    sum += texture2DCv(hBuf.texture, acScreenNorm + vec2(0.0, fi * texel.y)) * w;
                    total += w;
                }
                vec4 bloom = (sum / max(total, 0.0001)) * intensity;
                vec3 outRgb = base.rgb + bloom.rgb;
                float outA = clamp(base.a + bloom.a, 0.0, 1.0);
                gl_FragColor = vec4(outRgb, outA);
            }
        }
    ]]></shader>
</effect>
```

---

## 7. AI Prompting Checklist

When asking an AI to create a custom Alight Motion effect:
1. Attach this guide (`AlightMotion_Effects_Guide.md`).
2. Optionally attach `AlightMotion_All_Effects.md` if you want the AI to replicate or remix the math from a built-in effect.
3. Ask the AI to output a **single complete `<effect>...</effect>` XML** with:
   - `compat="acScreenNorm-y"`
   - Explicit floats (`0.0`, `1.0`) and constant loop bounds
   - `texture2DCv(inputImg.texture, ...)` and premultiplied-alpha-safe RGB math
   - Clear `<params>` controls (`spinner`, `slider`, `color`, `switch`, `selector`, `point`)
4. Paste the XML into **Add Effect -> Custom -> `+`** (or pick your target category), tap **Create**, and restart Alight Motion.
