# Prompting

Adapted from the `imagegen` skill bundled with OpenAI Codex (Apache-2.0, see [LICENSE-imagegen.txt](LICENSE-imagegen.txt)). Changed: rewritten for the `imgen` CLI and its providers, tool-mode notes removed, transparency section replaced.

## Structure

- Order: scene/backdrop → subject → key details → constraints → intended use.
- Say what the image is for (ad, UI mock, infographic, app icon); it sets the level of polish.
- For complex requests use short labeled lines instead of one long paragraph:

```text
Use case: <slug from the list below>
Asset type: <where the asset will be used>
Primary request: <the user's main ask>
Input images: <Image 1: role; Image 2: role>
Scene/backdrop: <environment>
Subject: <main subject>
Style/medium: <photo / illustration / 3D / ...>
Composition/framing: <wide / close / top-down; placement>
Lighting/mood: <lighting and mood>
Color palette: <palette notes>
Materials/textures: <surface details>
Text (verbatim): "<exact text>"
Constraints: <must keep / must avoid>
Avoid: <negative constraints>
```

Use only the lines that help. `Scene/backdrop` is the visual setting; it is not `--background`, which controls transparency.

## How much to add

- A specific, detailed prompt: keep its specificity, only tidy it into the structure above.
- A generic prompt: add detail only where it clearly improves the result.

Allowed additions: composition and framing cues, intended-use or polish hints, practical layout guidance, scene concreteness that supports the request.

Do not add: characters, props or objects the user did not imply; brand palettes, slogans or story beats; left/right placement the surrounding layout does not call for.

For photorealism write `photorealistic` and name real texture: pores, wrinkles, fabric wear, material grain, everyday imperfection.

## Composition

- Give framing and viewpoint (close-up, wide, top-down) and placement only when it matters.
- Ask for negative space when the asset needs room for UI or copy.
- For people, describe body framing, scale, gaze and interactions (`full body visible`, `looking down at the book`).

## Edits and invariants

- State what must not change: `change only X; keep Y unchanged`.
- Repeat the invariants on every iteration; without them edits drift.

## Text in images

- Put literal text in quotes or ALL CAPS, and give font style, size, color and placement.
- Spell rare words letter by letter when accuracy matters.
- Ask for verbatim rendering with no extra characters.
- Small text, dense infographics, slides with data, legends and axes need `--quality medium` or `high`.

## Input images

- Not every input image is an edit target. Label each by position and role: `Image 1: edit target`, `Image 2: style reference`.
- Images given only for style, composition or mood: it is a generation with references.
- "Keep this image but change X": it is an edit.
- For compositing, say how the images interact: `place the subject from Image 2 into Image 1`.

## Iterating

- Start from a clean base prompt, then change one thing at a time.
- Restate critical constraints each time.
- One targeted follow-up beats rewriting the whole prompt.

## Transparent backgrounds

With `--background transparent`, imgen either uses the model's native transparency or adds a flat chroma-key background instruction to the prompt and removes it locally. In the second case:

- Describe the subject only; do not write your own background instructions.
- Ask for a clean silhouette and crisp edges. Soft shadows, glow, smoke, glass and hair blend into the key color and cut out poorly; avoid them unless needed.
- A green subject (frog, leaf, logo in green): pass `--chroma-key '#ff00ff'`.

## Use-case slugs

Generate:

- `photorealistic-natural`: write as if a real photo was taken in the moment; photography language (lens, light, framing); real texture; no studio polish unless asked.
- `product-mockup`: product or packaging and its materials; clean silhouette; legible label; verbatim text and typography if text appears.
- `ui-mockup`: state the fidelity first (shippable mockup or low-fi wireframe), then layout, hierarchy and real UI elements; no concept-art language.
- `infographic-diagram`: audience and reading flow; label every part; verbatim text; higher quality for dense labels.
- `scientific-educational`: audience, learning goal, required labels, scientific constraints, arrows, whitespace.
- `ads-marketing`: write like a creative brief: positioning, audience, vibe, scene, exact tagline.
- `productivity-visual`: name the artifact (slide, chart, workflow diagram), canvas and hierarchy; give real labels and data.
- `logo-brand`: simple and scalable; strong silhouette, balanced negative space; no decoration unless asked.
- `illustration-story`: panels or scene beats, each action concrete.
- `stylized-concept`: style cues, material finish, rendering approach (3D, painterly, clay) without new story elements.
- `historical-scene`: place, date and the period accuracy required; clothing, props and setting must match the era.

Edit:

- `text-localization`: change only the text; keep layout, typography, spacing and hierarchy.
- `identity-preserve`: lock face, body, pose, hair and expression; change only what was asked; match lighting.
- `precise-object-edit`: say exactly what to remove or replace; keep surrounding texture and lighting.
- `lighting-weather`: change only light, shadow, atmosphere and weather; keep geometry, framing and identity.
- `background-extraction`: use `--background transparent`, or `imgen cutout` when the image already sits on a flat color.
- `style-transfer`: name the style cues to keep (palette, texture, brushwork) and what changes; add `no extra elements`.
- `compositing`: refer to inputs by position; say what goes where; match lighting, perspective and scale.
- `sketch-to-render`: keep layout, proportions and perspective; pick materials and lighting that fit the sketch.

Ready-to-adapt prompts for each slug are in [sample-prompts.md](sample-prompts.md).
