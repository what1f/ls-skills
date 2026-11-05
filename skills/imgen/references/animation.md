# GIF 动图

模型一次画出一张 sprite sheet（所有帧排成网格），`imgen animate` 在本地把它切开拼成 GIF。所有 provider 都按这条路做。

## 1. 定帧数和网格

| 动作 | 帧数 | 网格 | `--frame-ms` |
| --- | --- | --- | --- |
| 待机、呼吸、眨眼、表情变化 | 4–6 | 2x2、3x2 | 150–250 |
| 挥手、点头、说话、庆祝 | 6–9 | 3x2、3x3 | 100–150 |
| 跑、跳、攻击这类快动作 | 8–9 | 4x2、3x3 | 60–100 |

整张图的像素是固定的，格子越多每帧越小，9 格以上细节明显变差。动作要更长时，拆成几张 sheet 分别生成，再用同一组 `--grid`、`--frame-ms` 拼。

## 2. 写 prompt

按下面的模板写，每一行都保留：网格、读序、等大格子、固定机位、首尾衔接、禁止文字和分隔线，缺一项就容易出现格子大小不一、角色漂移或格子里带编号。

```text
Create a single animation sprite sheet for a seamless looping GIF.
Subject: <who or what; the traits that must stay identical in every frame>
Action: <the motion beat by beat, from the start pose back toward the start pose>
Exactly <N> sequential frames arranged in a precise <C>-column by <R>-row grid, read left-to-right then top-to-bottom. Every panel has identical dimensions.
Fixed <camera angle> camera; the same character, outfit, scale and position in every panel.
Clear incremental motion between frames; frame <N> transitions smoothly toward frame 1.
Style: <medium, lighting, palette>
Background: <a perfectly flat solid #00FF00 background with no shadow or texture | the scene, identical in every panel>
No captions, no words, no numbers, no logos, no speech bubbles, no panel labels, no borders, no gutters.
```

- 格子是正方形时，用 `--aspect <C>:<R>`（3x2 网格就是 `--aspect 3:2`）。
- 要透明 GIF：背景写纯色绿幕（主体是绿色时换成 `#FF00FF`），拼的时候加 `--transparent`。用户给了角色图时，用 `--image` 传入，在 prompt 里写 `Image 1: character reference; keep the design identical`。

官方示例（6 帧，3x2）：

```text
Create a single animation sprite sheet for a seamless looping GIF. A super-cute chibi adult office worker sits at a desk watching a computer monitor with a clearly plunging stock-market line chart. The sequence: hopeful expression, notices the chart falling, eyes widen, face crumples, large cartoon tears stream down both cheeks, then quietly wipes tears while still staring at the falling chart. Oversized round head, tiny body, big expressive eyes, soft rounded features, messy fluffy hair, white shirt and loosened tie. Exactly 6 sequential frames arranged in a precise 3-column by 2-row grid, read left-to-right then top-to-bottom. Every panel has identical dimensions. Fixed front three-quarter camera, same character, same desk, monitor, outfit, and cozy miniature office background. Clear incremental facial and tear motion; sixth frame transitions smoothly toward the first. Polished kawaii chibi 3D toy-like style, warm pastel lighting, funny and sympathetic mood. No captions, no words, no numbers, no logos, no speech bubbles, no panel labels, no borders, no gutters.
```

## 3. 检查 sheet

打开生成的 sheet 看一遍，数清楚实际画了几行几列、每格是不是同一个角色、有没有编号或分隔线。模型画的格数和要求不一致时，按实际网格传 `--grid`，多出的空格用 `--frames` 去掉；角色走样或格子不等大就重新生成。

## 4. 拼 GIF

```sh
imgen animate --image sheet.png --grid 3x2 --out wave.gif --frame-ms 120 --transparent --align bottom --format json
```

- `--transparent`：去掉纯色背景，背景色从 sheet 边缘自动取。sheet 本身已经带透明通道时不用加。
- `--align`：模型画的各格位置会有几像素偏差，播放时会抖。
  - `bottom`：站在地上的角色（待机、挥手、说话），脚保持在同一条线上
  - `center`：悬浮的物体、图标
  - `none`（默认）：动作本身就在移动整个身体时（跳、走过画面、弹跳），对齐会把这段位移抵消掉
- `--max-dim 256` 之类的值用来控制文件大小；表情包和聊天里的小图 128–256 就够。
- `--inset 4` 用于格子之间有分隔线或相邻格内容串过来的情况。

`warnings` 里的两条要处理：
- `frame N looks empty`：那一格没画东西，`--grid` 或 `--frames` 不对。
- `the subject touches the cell edge`：多数帧的主体被格子边缘切到，通常是 `--grid` 写错了；网格没错时是有分隔线，加 `--inset`。

## 5. 检查结果

GIF 看不到动起来的样子，用 `imgen sheet` 把成品的帧重新排成一张图来看，检查透明边缘、对齐和每帧的变化：

```sh
imgen sheet --image wave.gif --out wave-frames.png --format json
```

汇报 GIF 路径、sheet 路径和 prompt。要改动作时，把原 sheet 作为 `Image 1` 传入，写清楚哪几帧改什么，并保持网格不变，然后重新拼。

## 照着现有 GIF 重画

用户给的是 GIF 时，先排成 sheet 再当参考图：

```sh
imgen sheet --image ref.gif --out ref-sheet.png --cols 3 --format json
```

`data.grid` 是网格，`data.delays_ms` 是原来每帧的时长。prompt 写 `Image 1: a <C>x<R> animation sprite sheet; redraw every frame as <new style or character>, keeping the same grid, poses and timing`，再加上模板里网格、机位和禁止项那几行。生成后用同样的 `--grid` 和原来的帧时长拼回 GIF。
