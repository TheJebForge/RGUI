# RGUI
Immediate mode UI library for Retro Gadgets

## How to install
- Drop `ui.lua` file into `Import` folder inside your Gadget folder
- Import it to your gadget
- Require it as a module in your `CPU#.lua` file:
```lua
local ui = require("ui.lua")
```

## Core concepts
Every widget method of the library uses following types to describe themselves:
```luau
export type LayoutContext = {
	min: vec2,
	max: vec2,
	contain: (self: LayoutContext, pos: vec2) -> vec2,
	copy: (self: LayoutContext) -> LayoutContext
}

export type Buffer = {
	buffer: RenderBuffer,
	push: (self: Buffer, pos: vec2) -> Buffer,
	dirtyPush: (self: Buffer, pos: vec2) -> Buffer,
	pop: (self: Buffer) -> Buffer,
	draw: (self: Buffer) -> Buffer,
	release: () -> ()
}

export type DrawContext = {
	video: VideoChip,
	cpu: CPU,
	claimBuffer: (width: number, height: number) -> Buffer,
	posToScreen: (pos: vec2) -> vec2,
	screenToPos: (screen: vec2) -> vec2
}

export type Result = {
	size: vec2,
	draw: (pos: vec2, dctx: DrawContext) -> ()
}

export type LayoutFunc = (ctx: LayoutContext) -> Result
```
- **LayoutFunc** and **Result** - the thing that this whole library is based around, this represents a layouting function that will calculate how much size it needs to render, it then should return its size and a drawing function, drawing function will be called when the UI hierarchy is being rendered to the screen
- **LayoutContext** - layouting context, tells you the minimum and maximum size expected from your widget
  - `:contain(pos: vec2): vec2` - clamps provided position to fit inside `min` and `max`
  - `:copy()` - makes a copy of the context, so you can modify the copy rather than the original context
- **DrawContext** - drawing context, provides you things you would need to draw your widget on the screen
  - `.claimBuffer(width: number, height: number): Buffer` - lets you claim a buffer that you can use to "clip" whatever you're trying to render, make sure to release the buffer once you're done! Do not keep the buffer outside of the drawing function.
  - `.posToScreen(pos: vec2): vec2` - transforms your relative position of the widget to absolute position on the screen, this is needed because being drawn inside of a buffer, you'll be getting position relative to the buffer. Useful with `VideoChip.TouchPosition`
  - `.screenToPos(screen: vec2): vec2` - transforms absolute position on the screen to relative position of the widget, reverses previously mentioned transform.
- **Buffer** - wrapper around `RenderBuffer` to include functions that you'll likely going to be using to clip your widget contents
  - `:push(pos: vec2): Buffer` - clears the `RenderBuffer` and makes everything after this render to the `RenderBuffer` instead, `pos` tells where the buffer will be drawn later
  - `:dirtyPush(pos: vec2): Buffer` - same as above, but doesn't clear the buffer
  - `:pop(): Buffer` - returns rendering to whatever was there previously, call this after you're done rendering to the buffer.
  - `:draw(): Buffer` - draws contents of the buffer to the screen
  - `.release()` - releases the buffer, so it can be used by next things that have to render
### Example widgets:
So you can see concepts above in action
- Following widget takes in `PixelData` and returns a layouting function that returns size of the image and function to draw it. `PixelData` cannot be resized, so there's no point in trying to adhere to min and max of `ctx`
```luau
function ui.image(data: PixelData): LayoutFunc
	return function(ctx)
		return {
			size = vec2(data.Width, data.Height),
			draw = function(pos, dctx)
				dctx.video:BlitPixelData(pos, data)
			end
		}
	end
end
```
- Following widget creates a line that takes up the entire width of the context. This can then be used anytime you want a horizontal separator in your stacks/lists
```luau
function ui.horSeparator(clr: color): LayoutFunc
	return function(ctx)
		local size = vec2(
			ctx.max.X,
			3
		)
		
		return {
			size = size,
			draw = function(pos, dctx)
				dctx.video:DrawLine(
					pos + vec2(0, 1),
					pos + vec2(size.X - 1, 1),
					clr
				)
			end
		}
	end
end
```

## Helper functions
Functions you probably want to use for a simpler time working with this library
- `ui.layout(layoutFunc: LayoutFunc, video: VideoChip): Result` - takes in whatever widget hierarchy you came up with and lays it out into a `Result` that can be then drawn
- `ui.drawToScreen(layout: LayoutFunc | Result, video: VideoChip, cpu: CPU)` - renders your widget hierarchy or already calculated results to the screen
- `ui.context(min: vec2, max: vec2): LayoutContext` - creates a new layouting context that can be passed into widgets with whatever minimums and maximums you want from them
- `ui.contextFromVideo(video: VideoChip): LayoutContext` - same thing as above, but takes width and height of video chip's screen for context min and max
- `ui.drawContext(video: VideoChip, cpu: CPU): DrawContext` - creates a new drawing context if you for some reason want it

## Themes
This UI library also supports themes, themes contain all the colors included widgets will use and default settings. Themes have following properties:
```luau
export type Theme = {
	BG: color,
	SecondBG: color,
	inactiveFG: color,
	activeBG: color,
	activeFG: color,
	heldBG: color,
	heldFG: color,
	buttonInset: Inset,
	defaultFont: SpriteSheet,
	scrollThickness: number,
	useTouch: boolean
}
```
- `BG` - background color that should be used for the screen
- `SecondBG` - second background color that would appear on second level of the UI
- `inactiveFG` - aka normal text color
- `activeBG` - background color that "active" elements would use, think scroller in lists and buttons
- `activeFG` - text color that active elements would use
- `heldBG` - background color that elements would use while they're being pressed down
- `heldFG` - text color for pressed down elements
- `buttonInset` - inset that buttons will use by default
- `defaultFont` - font spritesheet that would be used by default for labels and buttons
- `scrollThickness` - default thickness of scrollers for `overflow` and `list`
- `useTouch` - if elements should respond at all to screen touches

The library comes with 2 default themes:

- `ui.whiteOnBlack(font: SpriteSheet): Theme` - black background and white text
- `ui.blackOnWhite(font: SpriteSheet): Theme` - white background and black text 

## Widgets that are included with this library
### Containers
Widgets that define the layout of your screen, all of them layout child widgets in one way or another
- `ui.inset(top: number, bottom: number, left: number, right: number): Inset` - this widget will inset a child widget with provided margins
  - `.top`, `.bottom`, `.left`, `.right` - margin properties  
  - `Inset:layout(child: LayoutFunc): LayoutFunc` - takes in a child widget to inset and returns its layouting function
- `ui.uniformInset(uni: number): Inset` - same as above, but all sides will have the same provided value

### Styled widgets
These widgets usually return a style rather than directly returning a layouting function, you should create them at start of your CPU and keep them around. Styles don't have state, so this is done just for less things you'd constantly have to repeat while creating your UI
- `ui.label(theme: Theme): TextStyle` - this widget will render text
  - `.font: SpriteSheet` - font that will be used for the text
  - `.fallbackColor: color` - color that will be used when it's not provided in `:layout` function
  - `:layout(text: string, clr: color?): LayoutFunc` - takes in text to render and optionally color to use, fallbacks to `fallbackColor` if no color is provided
- `ui.customLabel(font: SpriteSheet, fallback: color): TextStyle` - same as above, but lets you provide custom font and color
- `ui.sprite(sheet: SpriteSheet, spriteX: number, spriteY: number): SpriteStyle` - this will render a sprite from provided spritesheet
  - `.sheet: SpriteSheet` - provided spritesheet
  - `.pos: vec2` - grid position on the spritesheet
  - `:layout(clr: color): LayoutFunc` - takes in color and renders the sprite with the color being used for tint
- `ui.progress(theme: Theme): ProgressStyle` - this will render a progress bar
  - `.height: number` - height of the progress bar, by default it will try to match height of your font
  - `.minWidth: number` - minimum width of the progress bar in pixels, by default it's `50`
  - `.color: color` - color of the progress bar
  - `:layout(expand: boolean, progress: number): LayoutFunc` - renders a progress bar. If `expand` is true, it will take up as much space as it can horizontally. `progress` is a number between 0 and 1

### Stateful widgets
Widgets that require a separately provided state to function, you do want to keep your list scroll position, right?


### Simple widgets
Widgets that don't have much complexity
- `ui.empty(): LayoutFunc` - empty widget whenever you want to have nothing
- `ui.image(data: PixelData): LayoutFunc` - simply renders whatever image you provide

### Helper widgets
Helpers that will do various things to your layout
