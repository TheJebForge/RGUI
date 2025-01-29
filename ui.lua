--!strict

local ui = {}

-- Types

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

-- Utils

local function posInside(target: vec2, min: vec2, max: vec2)
	if target.X >= min.X and target.X <= max.X 
		and target.Y >= min.Y and target.Y <= max.Y then
		return true
	end

	return false
end

local function rectOnScreen(pos: vec2, size: vec2, screenSize: vec2): boolean
	return pos.X < screenSize.X and pos.X + size.X > 0 and
        pos.Y < screenSize.Y and pos.Y + size.Y > 0
end

local function rect(
	x: number, 
	y: number, 
	w: number, 
	h: number
): (vec2, vec2)
	return vec2(x, y), vec2(x + w - 1, y + h - 1)
end

local function rectEnd(
	pos: vec2,
	size: vec2
): vec2
	return pos + size - vec2(1, 1)
end

local function clamp(value: number, min: number, max: number): number
	return math.min(max, math.max(value, min))
end

local function clamp01(value: number): number
	return clamp(value, 0, 1)
end

-- Core functions

function ui.context(min: vec2, max: vec2): LayoutContext
	return {
		min = min,
		max = max,
		contain = function(self, pos)
			return vec2(
				clamp(pos.X, self.min.X, self.max.X),
				clamp(pos.Y, self.min.Y, self.max.Y)
			)
		end,
		copy = function(self)
			return ui.context(self.min, self.max)
		end
	}
end


function ui.contextFromVideo(video: VideoChip): LayoutContext
	local size = vec2(video.Width, video.Height)
	return ui.context(size, size)
end

function ui.drawContext(video: VideoChip, cpu: CPU): DrawContext
	local claimedBuffers: {Buffer} = {}
	local currentTarget = 0
	local currentOffset = vec2(0, 0)
	
	local function wrapBuffer(index: number, buffer: RenderBuffer): Buffer
		local lastTarget = nil
		local targetPos = vec2(0, 0)
		return {
			buffer = buffer,
			push = function(self, pos)
				self:dirtyPush(pos)
				video:Clear(color.clear)
				return self
			end,
			dirtyPush = function(self, pos)
				targetPos = pos
			  lastTarget = currentTarget
				currentTarget = index
				currentOffset += pos
				video:RenderOnBuffer(index)
				return self
			end,
			pop = function(self)
				if lastTarget then
					if lastTarget == 0 then
						video:RenderOnScreen()
					else
						video:RenderOnBuffer(lastTarget)
					end
					currentTarget = lastTarget
					currentOffset -= targetPos
				end
				
				return self
			end,
			draw = function(self)
				video:DrawRenderBuffer(targetPos, buffer, buffer.Width, buffer.Height)
				return self
			end,
			release = function()
				claimedBuffers[index] = nil
			end
		}
	end
	
	local function pickBufferIndex(): number?
		local max = #video.RenderBuffers
		
		for i = 1, max do
			if not claimedBuffers[i] then
				return i
			end
		end
		
		return nil
	end
	
	return {
		video = video,
		cpu = cpu,
		claimBuffer = function(width, height)
			local index = pickBufferIndex()
			
			assert(index, "Buffer limit exceeded!")
			
			video:SetRenderBufferSize(index, width, height)
			claimedBuffers[index] = wrapBuffer(
				index,
				video.RenderBuffers[index]
			)
			
			return claimedBuffers[index]
		end,
		posToScreen = function(pos)
			return pos + currentOffset
		end,
		screenToPos = function(screen)
			return screen - currentOffset
		end
	}
end

function ui.layout(layoutFunc: LayoutFunc, video: VideoChip): Result
	local ctx = ui.contextFromVideo(video)
	return layoutFunc(ctx)
end

function ui.drawToScreen(layout: LayoutFunc | Result, video: VideoChip, cpu: CPU)
	local dctx = ui.drawContext(video, cpu)
	if typeof(layout) == "function" then
		local ctx = ui.contextFromVideo(video)
		local result = layout(ctx)
		result.draw(vec2(0, 0), dctx)
	elseif typeof(layout) == "table" then
		layout.draw(vec2(0, 0), dctx)
	end
end

-- UI Stuff

export type Inset = {
	top: number,
	bottom: number,
	left: number,
	right: number,
	layout: (self: Inset, child: LayoutFunc) -> LayoutFunc
}

function ui.inset(
	top: number,
	bottom: number,
	left: number,
	right: number
): Inset
	return {
		top = top,
		bottom = bottom,
		left = left,
		right = right,
		layout = function(self, child)
			return function(ctx)
				local lctx = ctx:copy()
				lctx.max = vec2(
					ctx.max.X - (self.left + self.right),
					ctx.max.Y - (self.top + self.bottom) 
				)
			
				local result = child(lctx)
				
				return {
					size = vec2(
						self.left + result.size.X + self.right,
						self.top + result.size.Y + self.bottom
					),
					draw = function(pos, dctx)
						result.draw(pos + vec2(
							self.left,
							self.top
						), dctx)
					end
				}
			end
		end
	}
end

function ui.uniformInset(uni: number): Inset
	return ui.inset(uni, uni, uni, uni)
end

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

function ui.whiteOnBlack(font: SpriteSheet): Theme
	return {
		BG = color.black,
		SecondBG = ColorHSV(0, 0, 20),
		inactiveFG = color.white,
		activeBG = color.white,
		activeFG = color.black,
		heldBG = color.gray,
		heldFG = color.white,
		buttonInset = ui.uniformInset(1),
		defaultFont = font,
		scrollThickness = 4,
		useTouch = true
	}
end

function ui.blackOnWhite(font: SpriteSheet): Theme
	return {
		BG = color.white,
		SecondBG = ColorHSV(0, 0, 70),
		inactiveFG = color.black,
		activeBG = color.gray,
		activeFG = color.black,
		heldBG = color.black,
		heldFG = color.white,
		buttonInset = ui.uniformInset(1),
		defaultFont = font,
		scrollThickness = 4,
		useTouch = true
	}
end

function ui.empty(): LayoutFunc
	return function(ctx)
		return {
			size = vec2(0, 0),
			draw = function(pos, dctx) end
		}
	end
end

export type TextStyle = {
	font: SpriteSheet,
	fallbackColor: color,
	layout: (self: TextStyle, text: string, clr: color?) -> LayoutFunc
}

function ui.label(theme: Theme): TextStyle
	return ui.customLabel(theme.defaultFont, theme.inactiveFG)
end

function ui.customLabel(font: SpriteSheet, fallback: color): TextStyle
	return {
		font = font,
		fallbackColor = fallback,
		layout = function(self, text, clr)
			local char = self.font:GetSpritePixelData(0, 0)
	
			return function(ctx)
				local size = vec2(
					char.Width * text:len() + 1,
					char.Height + 1
				)
		
				return {
					size = size,
					draw = function(pos, dctx)
						dctx.video:DrawText(
							pos + vec2(1, 1), 
							self.font, 
							text, 
							clr or self.fallbackColor, 
							color.clear
						)
					end
				}
			end
		end
	}	
end

export type SpriteStyle = {
	sheet: SpriteSheet,
	pos: vec2,
	layout: (self: SpriteStyle, clr: color) -> LayoutFunc
}

function ui.sprite(sheet: SpriteSheet, spriteX: number, spriteY: number): SpriteStyle
	local spr = sheet:GetSpritePixelData(0, 0)
	local size = vec2(spr.Width, spr.Height)
	
	return {
		sheet = sheet,
		pos = vec2(spriteX, spriteY),
		layout = function(self, clr)
			return function(ctx)
				return {
					size = size,
					draw = function(pos, dctx)
						dctx.video:DrawSprite(pos, self.sheet, self.pos.X, self.pos.Y, clr, color.clear)
					end
				}
			end
		end
	}
end

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

ui.HORIZONTAL = 0
ui.VERTICAL = 1
ui.BOTH = 2

ui.START = 0
ui.MIDDLE = 1
ui.END = 2

function ui.stack(
	axis: number?, 
	alignment: number?, 
	gap: number?, 
	...: LayoutFunc
): LayoutFunc
	local axis = axis or ui.HORIZONTAL
	local alignment = alignment or ui.START
	local gap = gap or 0
	local children = {...}
	
	return function(ctx)
		local size = vec2(0, 0)
		local results = {}
		
		local lctx = ctx:copy()
		lctx.min = vec2(0, 0)
		
		for i = 1, #children do
			local child = children[i]
			local result = child(lctx)
			local currentGap = i == 1 and 0 or gap
			
			if axis == ui.HORIZONTAL then
				size = vec2(
					size.X + result.size.X + currentGap, 
					size.Y
				)
			
				if size.Y < result.size.Y then
					size = vec2(size.X, result.size.Y)
				end
			elseif axis == ui.VERTICAL then
				size = vec2(
					size.X,
					size.Y + result.size.Y + currentGap
				)
				
				if size.X < result.size.X then
					size = vec2(result.size.X, size.Y)
				end
			end
			
			table.insert(results, result)
		end
		
		return {
			size = vec2(
				math.max(size.X, ctx.min.X),
				math.max(size.Y, ctx.min.Y)
			),
			draw = function(pos, dctx)
				local crossSize
				if axis == ui.HORIZONTAL then
					crossSize = size.Y
				else
				  crossSize = size.X	
				end
				
				local mainOffset = 0
				local crossOffset = 0
				
				for i = 1, #results do
					local result = results[i]
					
					local main, cross
					if axis == ui.HORIZONTAL then
						main = result.size.X
						cross = result.size.Y
					else
						main = result.size.Y
						cross = result.size.X	
					end
					
					if alignment == ui.START then
						crossOffset = 0
					elseif alignment == ui.MIDDLE then
						crossOffset = crossSize / 2 - cross / 2
					elseif alignment == ui.END then
						crossOffset = crossSize - cross
					end
					
					local xOffset, yOffset
					if axis == ui.HORIZONTAL then
						xOffset = mainOffset
						yOffset = crossOffset
					else
						yOffset = mainOffset
						xOffset = crossOffset	
					end
					
					result.draw(
						pos + vec2(xOffset, yOffset), 
						dctx
					)
					
					mainOffset = mainOffset + main + gap
				end
			end
		}
	end
end

function ui.background(color: color, child: LayoutFunc): LayoutFunc
	return function(ctx)
		local result = child(ctx)
		return {
			size = result.size,
			draw = function(pos, dctx)
				dctx.video:FillRect(pos, rectEnd(pos, result.size), color)
				result.draw(pos, dctx)
			end
		}
	end
end

function ui.frame(color: color, child: LayoutFunc): LayoutFunc
	return function(ctx)
		local result = child(ctx)
		return {
			size = result.size,
			draw = function(pos, dctx)
				dctx.video:DrawRect(pos, rectEnd(pos, result.size), color)
				result.draw(pos, dctx)
			end
		}
	end
end

export type ScrollState = {
	offset: number,
	scrolling: boolean,
	holdOffset: vec2
}

function ui.scrollState(): ScrollState
	return {
		offset = 0,
		scrolling = false,
		holdOffset = vec2(0, 0)
	}
end

export type OverflowState = {
	hor: ScrollState,
	ver: ScrollState
}

function ui.overflowState(): OverflowState
	return {
		hor = ui.scrollState(),
		ver = ui.scrollState()
	}
end

local function processScroll(
	theme: Theme,
	axis: number,
	state: ScrollState,
	dctx: DrawContext, 
	pos: vec2, 
	innerSize: vec2,
	maxSize: vec2,
	thickness: number
)
	local innerSpace, maxSpace
	if axis == ui.HORIZONTAL then
		innerSpace = innerSize.X
		maxSpace = maxSize.X
	else
		innerSpace = innerSize.Y
		maxSpace = maxSize.Y
	end
	
	local scrollerRatio = math.min(
		innerSpace / maxSpace,
		1
	)
	
	local scrollerSize = math.floor(
		scrollerRatio * innerSpace
	)
	
	local maxScroll = math.max(
		0,
		maxSpace - innerSpace
	)
	
	state.offset = clamp(state.offset, 0, maxScroll)
	
	local scrollerOffset = math.floor(
		scrollerRatio * state.offset
	)
	
	local scrollerStart, scrollerEnd
	if axis == ui.HORIZONTAL then
		scrollerStart = pos + vec2(
			scrollerOffset,
			innerSize.Y
		)
							
		scrollerEnd = pos + vec2(
			scrollerOffset + scrollerSize - 1,
			innerSize.Y + thickness - 1
		)
	else
		scrollerStart = pos + vec2(
			innerSize.X,
			scrollerOffset
		)
							
		scrollerEnd = pos + vec2(
			innerSize.X + thickness - 1,
			scrollerOffset + scrollerSize - 1
		)
	end
	
	if theme.useTouch then
		local rPos = dctx.posToScreen(pos)
		local rScrollerStart = dctx.posToScreen(scrollerStart)
		local rScrollerEnd = dctx.posToScreen(scrollerEnd)
		
		local down = dctx.video.TouchDown
		local held = dctx.video.TouchState
		local tPos = dctx.video.TouchPosition
		local relPos = tPos - rPos
		
		if not state.scrolling then
			if down and posInside(tPos, rScrollerStart, rScrollerEnd) then
				local scrollOffset = relPos - scrollerStart
				
				state.scrolling = true
				state.holdOffset = scrollOffset
			end
		else
			if not held then
				state.scrolling = false
			else
				local oPos = relPos - state.holdOffset - pos
					
				local scaledTargetScroll
				if axis == ui.HORIZONTAL then
					scaledTargetScroll = math.floor(oPos.X / scrollerRatio)
				else
					scaledTargetScroll = math.floor(oPos.Y / scrollerRatio)
				end
				
				state.offset = scaledTargetScroll
			end
		end
	end
	
	local bgStart, bgEnd
	if axis == ui.HORIZONTAL then
		bgStart = pos + vec2(
			0,
			innerSize.Y
		)
		bgEnd = pos + vec2(
			innerSize.X - 1,
			innerSize.Y + thickness - 1
		)
	else
		bgStart = pos + vec2(
			innerSize.X,
			0
		)
		bgEnd = pos + vec2(
			innerSize.X + thickness - 1,
			innerSize.Y - 1
		)
	end
							
	dctx.video:FillRect(
		bgStart,
		bgEnd,
		theme.SecondBG
	)
							
	dctx.video:FillRect(
		scrollerStart,
		scrollerEnd,
		state.scrolling and theme.heldBG or theme.activeBG
	)
end

function ui.overflow(
	theme: Theme,
	state: OverflowState,
	axis: number?, 
	child: LayoutFunc
): LayoutFunc
		local axis = axis or ui.HORIZONTAL
		
		return function(ctx)
			local lctx = ctx:copy()
			lctx.min = vec2(0, 0)
			if axis == ui.HORIZONTAL then
				lctx.max = vec2(
					math.huge, 
					ctx.max.Y - theme.scrollThickness
				)
			elseif axis == ui.VERTICAL then
				lctx.max = vec2(
					ctx.max.X - theme.scrollThickness, 
					math.huge
				)
			else
				lctx.max = vec2(math.huge, math.huge)	
			end
			
			local hScrollThickness, vScrollThickness = 0, 0
			if axis == ui.HORIZONTAL then
				hScrollThickness = theme.scrollThickness
			elseif axis == ui.VERTICAL then
				vScrollThickness = theme.scrollThickness
			else
				hScrollThickness = theme.scrollThickness
				vScrollThickness = theme.scrollThickness	
			end
			
			local result = child(lctx)
			local size = vec2(
				math.min(
					math.max(
						result.size.X + vScrollThickness,
						ctx.min.X
					),
					ctx.max.X
				),
				math.min(
					math.max(
						result.size.Y + hScrollThickness,
						ctx.min.Y
					),
					ctx.max.Y
				)
			)
			local innerSize = vec2(
				size.X - vScrollThickness,
				size.Y - hScrollThickness
			)
			
			local hScrollPossible = (axis == ui.HORIZONTAL or axis == ui.BOTH) and hScrollThickness > 0
			local vScrollPossible = (axis == ui.VERTICAL or axis == ui.BOTH) and vScrollThickness > 0
			
			local xOverflowing = result.size.X > innerSize.X 
			local yOverflowing = result.size.Y > innerSize.Y
			local overflowing = xOverflowing or yOverflowing
			
			return {
				size = size,
				draw = function(pos, dctx)
					if overflowing then
						-- Draw/process horizontal scroller
						
						if xOverflowing and hScrollPossible then
							processScroll(
								theme,
								ui.HORIZONTAL,
								state.hor,
								dctx,
								pos,
								innerSize,
								result.size,
								hScrollThickness
							)
						end
						
						-- Draw/process vertical scroller
						
						if yOverflowing and vScrollPossible then
							processScroll(
								theme,
								ui.VERTICAL,
								state.ver,
								dctx,
								pos,
								innerSize,
								result.size,
								vScrollThickness
							)
						end
						
						-- Draw actual content
						local buffer = dctx.claimBuffer(
							innerSize.X,
							innerSize.Y
						):push(pos)
						
						result.draw(vec2(
							-state.hor.offset,
							-state.ver.offset
						), dctx)
						
						buffer:pop():draw().release()
					else
					  result.draw(pos, dctx)	
					end
				end
			}
		end
end

export type FlexChild = {
	flex: number,
	rigid: boolean,
	widget: LayoutFunc
}

function ui.flexed(flex: number, widget: LayoutFunc): FlexChild
	return {
		flex = flex,
		rigid = false,
		widget = widget
	}
end

function ui.rigid(widget: LayoutFunc): FlexChild
	return {
		flex = 0,
		rigid = true,
		widget = widget
	}
end

type ResultWithSpace = {
	result: Result?,
	child: FlexChild?,
	space: number
}

function ui.flex(
	axis: number?, 
	alignment: number?, 
	possibleExpand: boolean?, 
	...: FlexChild
): LayoutFunc
	local axis = axis or ui.HORIZONTAL
	local alignment = alignment or ui.START
	
	local expand = false
	if type(possibleExpand) == "boolean" then
		expand = possibleExpand
	end
	
	local children = {...}
	
	return function(ctx)
		local results: {ResultWithSpace} = {}
		
		local totalCross = 0
		local totalRigidUnits = 0
		local totalFlex = 0
		
		local lctx = ctx:copy()
		lctx.min = vec2(0, 0)
		
		-- Layout rigids first to see how much space is left
		for i = 1, #children do
			local child = children[i]
			if not child.rigid then
				totalFlex += child.flex
				table.insert(results, {
					child = child,
					space = 0
				})
			else
				local result = child.widget(lctx)
				
				local space
				if axis == ui.HORIZONTAL then
					space = result.size.X
					totalCross = math.max(totalCross, result.size.Y)
				else
					space = result.size.Y
					totalCross = math.max(totalCross, result.size.X)
				end
				totalRigidUnits += space
				
				table.insert(results, {
					result = result,
					space = space
				})
			end
		end
		
		-- Calculate total available space
		local totalSpace
		if axis == ui.HORIZONTAL then
			if expand then
				totalSpace = ctx.max.X
			else
				totalSpace = math.max(totalRigidUnits, ctx.min.X)
			end
		else
			if expand then
				totalSpace = ctx.max.Y
			else
				totalSpace = math.max(totalRigidUnits, ctx.min.Y)
			end
		end
		
		local totalFlexSpace = totalSpace - totalRigidUnits
		local flexUnit = totalFlexSpace / totalFlex
		
		-- Layout flexed now into remaining space
		for i = 1, #results do
			local spaced = results[i]
			if not spaced.child then
				continue
			end
			
			local child = spaced.child :: FlexChild
			local allowedSpace = flexUnit * child.flex
			local lctx
			if axis == ui.HORIZONTAL then
				lctx = ui.context(
					vec2(allowedSpace, 0),
					vec2(allowedSpace, ctx.max.Y)
				)
			else
				lctx = ui.context(
					vec2(0, allowedSpace),
					vec2(ctx.max.X, allowedSpace)
				)
			end
			
			local result = child.widget(lctx)
			
			if axis == ui.HORIZONTAL then
				totalCross = math.max(totalCross, result.size.Y)
			else
				totalCross = math.max(totalCross, result.size.X)
			end
			
			spaced.result = result
			spaced.space = allowedSpace
		end
		
		local size
		if axis == ui.HORIZONTAL then
			size = vec2(
				totalSpace,
				totalCross
			)
		else
			size = vec2(
				totalCross,
				totalSpace
			)
		end
		
		return {
			size = size,
			draw = function(pos, dctx)
				local crossSize
				if axis == ui.HORIZONTAL then
					crossSize = size.Y
				else
					crossSize = size.X
				end
				
				local mainOffset = 0
				local crossOffset = 0
				
				for i = 1, #results do
					local spaced = results[i]
					local spacedResult = spaced.result :: Result
					
					local main = spaced.space
					local cross
					if axis == ui.HORIZONTAL then
						cross = spacedResult.size.Y
					else
						cross = spacedResult.size.X	
					end
					
					if alignment == ui.START then
						crossOffset = 0
					elseif alignment == ui.MIDDLE then
						crossOffset = crossSize / 2 - cross / 2
					elseif alignment == ui.END then
						crossOffset = crossSize - cross
					end
					
					local xOffset, yOffset
					if axis == ui.HORIZONTAL then
						xOffset = mainOffset
						yOffset = crossOffset
					else
						yOffset = mainOffset
						xOffset = crossOffset	
					end
					
					spacedResult.draw(
						pos + vec2(xOffset, yOffset), 
						dctx
					)
					
					mainOffset = mainOffset + main
				end
			end
		}
	end
end

function ui.contain(child: LayoutFunc): LayoutFunc
	return function(ctx)
		local result = child(ctx)
		local size = ctx:contain(result.size)
		return {
			size = size,
			draw = function(pos, dctx)
				local buf = dctx.claimBuffer(
					size.X,
					size.Y
				):push(pos)
				
				result.draw(vec2(0, 0), dctx)
				
				buf:pop():draw().release()
			end
		}
	end
end

function ui.limitX(limit: number, child: LayoutFunc): LayoutFunc
	return function(ctx)
		local lctx = ui.context(
			vec2(
				math.min(ctx.min.X, limit),
				ctx.min.Y
			),
			vec2(
				limit,
				ctx.max.Y
			)
		)
		
		return child(lctx)
	end
end

function ui.limitY(limit: number, child: LayoutFunc): LayoutFunc
	return function(ctx)
		local lctx = ui.context(
			vec2(
				ctx.min.X,
				math.min(ctx.min.Y, limit)
			),
			vec2(
				ctx.max.X,
				limit
			)
		)
		
		return child(lctx)
	end
end

function ui.minX(min: number, child: LayoutFunc): LayoutFunc
	return function(ctx)
		local lctx = ui.context(
			vec2(
				min,
				ctx.min.Y
			),
			ctx.max
		)
		
		return child(lctx)
	end
end

function ui.minY(min: number, child: LayoutFunc): LayoutFunc
	return function(ctx)
		local lctx = ui.context(
			vec2(
				ctx.min.X,
				min
			),
			ctx.max
		)
		
		return child(lctx)
	end
end

function ui.wSpacer(space: number): LayoutFunc
	return function(ctx)
		return {
			size = vec2(
				space,
				ctx.min.Y
			),
			draw = function(pos, dctx) end
		}
	end
end

function ui.hSpacer(space: number): LayoutFunc
	return function(ctx)
		return {
			size = vec2(
				ctx.min.X,
				space
			),
			draw = function(pos, dctx) end
		}
	end
end

function ui.flexWSpacer(space: number): FlexChild
	return ui.rigid(ui.wSpacer(space))
end

function ui.flexHSpacer(space: number): FlexChild
	return ui.rigid(ui.hSpacer(space))
end

function ui.emptyFlex(flex: number): FlexChild
	return ui.flexed(flex, ui.empty())
end

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

function ui.verSeparator(clr: color): LayoutFunc
	return function(ctx)
		local size = vec2(
			3,
			ctx.max.Y
		)
		
		return {
			size = size,
			draw = function(pos, dctx)
				dctx.video:DrawLine(
					pos + vec2(1, 0),
					pos + vec2(1, size.Y - 1),
					clr
				)
			end
		}
	end
end

function ui.flexHorSeparator(clr: color): FlexChild
	return ui.rigid(ui.horSeparator(clr))
end

function ui.flexVerSeparator(clr: color): FlexChild
	return ui.rigid(ui.verSeparator(clr))
end

function ui.center(child: LayoutFunc): LayoutFunc
	return function(ctx)
		local result = child(ctx)
		return {
			size = ctx.max,
			draw = function(pos, dctx)
				local offset = vec2(
					ctx.max.X / 2 - result.size.X / 2,
					ctx.max.Y / 2 - result.size.Y / 2
				)
				result.draw(pos + offset, dctx)
			end
		}
	end
end

local function scrollingLerp(time: number, stayTime: number, lerpTime: number): number
	local totalTime = stayTime * 2 + lerpTime * 2
	local modTime = time % totalTime
	local positive = clamp01((modTime - stayTime) / lerpTime)
	local negative = 1 - clamp01((modTime - stayTime * 2 - lerpTime) / lerpTime)
	return positive * negative
end

export type ScrollingSync = {
	maxLerp: number,
	checkMax: (self: ScrollingSync, max: number) -> (),
	reset: (self: ScrollingSync) -> ()
}

function ui.scrollingSync(): ScrollingSync
	return {
		maxLerp = 0,
		checkMax = function(self, max)
			if self.maxLerp < max then
				self.maxLerp = max
			end
		end,
		reset = function(self)
			self.maxLerp = 0
		end
	}
end

export type ScrollingLabelStyle = {
	style: TextStyle,
	stayTime: number,
	speed: number,
	speedAsLerpTime: boolean,
	sync: ScrollingSync?,
	layout: (self: ScrollingLabelStyle, text: string, clr: color?) -> LayoutFunc
}

function ui.scrollingLabel(
	style: TextStyle, 
	stayTime: number, 
	speed: number,
	asLerpTime: boolean,
	sync: ScrollingSync?
): ScrollingLabelStyle
	return {
		style = style,
		stayTime = stayTime,
		speed = speed,
		speedAsLerpTime = asLerpTime,
		sync = sync,
		layout = function(self, text, clr)
			local char = self.style.font:GetSpritePixelData(0, 0)
			local textWidth = char.Width * text:len() + 1
			
			return function(ctx)
				local size = vec2(
					ctx.max.X,
					math.max(ctx.min.Y, char.Height + 1)
				)
				
				local lerpTime = self.speedAsLerpTime and speed or (textWidth - size.X) / speed
				local stayTime = self.stayTime
				local offset = 0
			
				if self.sync then
					self.sync:checkMax(lerpTime)
					offset = self.sync.maxLerp - lerpTime
					stayTime += offset
				end
				
				return {
					size = size,
					draw = function(pos, dctx)
						if textWidth > size.X then
							local buffer = dctx.claimBuffer(size.X, size.Y):push(pos)
							
							local curPos = scrollingLerp(dctx.cpu.Time + offset, stayTime, lerpTime)
							local offset = (textWidth - size.X) * curPos
							
							dctx.video:DrawText(
								vec2(-offset + 1, 1), 
								self.style.font, 
								text, 
								clr or self.style.fallbackColor, 
								color.clear
							)
							
							buffer:pop():draw().release()
						else
							dctx.video:DrawText(
								pos + vec2(1, 1), 
								self.style.font, 
								text, 
								clr or self.style.fallbackColor, 
								color.clear
							)
						end
					end
				}
			end
		end
	}
end

export type ButtonState = {
	held: boolean,
	lastPos: vec2,
	callback: () -> any
}

function ui.buttonState(callback: () -> any): ButtonState
	return {
		held = false,
		lastPos = vec2(0, 0),
		callback = callback
	}
end

export type ButtonStyle = {
	BG: color,
	FG: color,
	heldBG: color,
	heldFG: color,
	inset: Inset,
	font: SpriteSheet,
	layout: (self: ButtonStyle, state: ButtonState, text: string) -> LayoutFunc
}

function ui.button(theme: Theme): ButtonStyle
	return {
		BG = theme.activeBG,
		FG = theme.activeFG,
		heldBG = theme.heldBG,
		heldFG = theme.heldFG,
		inset = theme.buttonInset,
		font = theme.defaultFont,
		layout = function(self, state, text)
			local buttonText = ui.customLabel(self.font, self.FG)
			
			return function(ctx)
				local content = self.inset:layout(
					buttonText:layout(text)
				)
				
				local result = content(ctx)
				
				return {
					size = result.size,
					draw = function(pos, dctx)
						local pEnd = rectEnd(pos, result.size)
						local rPos = dctx.posToScreen(pos)
						local rEnd = rectEnd(rPos, result.size)
						
						local down = dctx.video.TouchDown
						local held = dctx.video.TouchState
						local tPos = dctx.video.TouchPosition
						
						if not state.held then
							if down and posInside(tPos, rPos, rEnd) then
								state.held = true
							end
						else
							if not held then
								state.held = false
	
								if posInside(state.lastPos, rPos, rEnd) then
									state.callback()
								end
							end
						end
						
						if held then
							state.lastPos = tPos
						end
						
						local BG, FG = self.BG, self.FG
						if state.held then
							BG = self.heldBG
							FG = self.heldFG
						end
						
						buttonText.fallbackColor = FG
						
						dctx.video:FillRect(pos, pEnd, BG)
						result.draw(pos, dctx)
					end
				}
			end
		end
	}
end

export type ListState = {
	scroll: ScrollState,
	axis: number,
	alignment: number,
	gap: number,
	thickness: number?,
	offsets: {{offset: number, size: vec2}},
	lastScreenSize: vec2,
	scrollToIndex: (self: ListState, index: number) -> ()
}

function ui.listState(
	axis: number?, 
	alignment: number?, 
	gap: number?, 
	thickness: number?
): ListState
	return {
		scroll = ui.scrollState(),
		axis = axis or ui.HORIZONTAL,
		alignment = alignment or ui.START,
		gap = gap or 0,
		thickness = thickness,
		offsets = {},
		lastScreenSize = vec2(0, 0),
		scrollToIndex = function(self, index)
			if index >= 1 and index <= #self.offsets then
				local target = self.offsets[index]
				
				local screenSpace, targetSpace
				if self.axis == ui.HORIZONTAL then
					screenSpace = self.lastScreenSize.X
					targetSpace = target.size.X
				else
					screenSpace = self.lastScreenSize.Y
					targetSpace = target.size.Y
				end
				
				if target.offset < self.scroll.offset then
					self.scroll.offset = target.offset
				elseif target.offset + targetSpace > self.scroll.offset + screenSpace then
					self.scroll.offset = target.offset - (screenSpace - targetSpace)
				end
			end
		end
	}
end

export type ListElementFunc = (index: number) -> LayoutFunc

function ui.list(
	theme: Theme,
	state: ListState,
	amount: number,
	template: ListElementFunc
): LayoutFunc
	local axis = state.axis
	local alignment = state.alignment
	local gap = state.gap
	
	return function(ctx)
		local contentSize = vec2(0, 0)
		local results = {}
		
		state.offsets = {}
		
		local lctx = ctx:copy()
		lctx.min = vec2(0, 0)
		
		local thickness = state.thickness or theme.scrollThickness
		
		if axis == ui.HORIZONTAL then
			lctx.max = vec2(
				math.huge, 
				ctx.max.Y - thickness
			)
		else
			lctx.max = vec2(
				ctx.max.X - thickness, 
				math.huge
			)
		end
		
		for i = 1, amount do
			local child = template(i)
			local result = child(lctx)
			local currentGap = i == 1 and 0 or gap
			
			local offset
			if axis == ui.HORIZONTAL then
				offset = contentSize.X + currentGap
				
				contentSize = vec2(
					offset + result.size.X, 
					contentSize.Y
				)
			
				if contentSize.Y < result.size.Y then
					contentSize = vec2(contentSize.X, result.size.Y)
				end
			elseif axis == ui.VERTICAL then
				offset = contentSize.Y + currentGap
				
				contentSize = vec2(
					contentSize.X,
					offset + result.size.Y
				)
				
				if contentSize.X < result.size.X then
					contentSize = vec2(result.size.X, contentSize.Y)
				end
			end
			
			table.insert(results, result)
			table.insert(state.offsets, {offset = offset, size = result.size})
		end

		local hScrollThickness, vScrollThickness = 0, 0
		if axis == ui.HORIZONTAL then
			hScrollThickness = thickness
		else
			vScrollThickness = thickness	
		end

		local size = vec2(
			math.min(
				math.max(
					contentSize.X,
					ctx.min.X
				) + vScrollThickness,
				ctx.max.X
			),
			math.min(
				math.max(
					contentSize.Y,
					ctx.min.Y
				) + hScrollThickness,
				ctx.max.Y
			)
		)
		local innerSize = vec2(
			size.X - vScrollThickness,
			size.Y - hScrollThickness
		)
		
		state.lastScreenSize = innerSize
		
		local hScrollPossible = axis == ui.HORIZONTAL and hScrollThickness > 0
		local vScrollPossible = axis == ui.VERTICAL and vScrollThickness > 0
		
		local xOverflowing = contentSize.X > innerSize.X 
		local yOverflowing = contentSize.Y > innerSize.Y
		local overflowing = xOverflowing or yOverflowing
		
		return {
			size = size,
			draw = function(pos, dctx)
				local buffer: Buffer? = nil
				if overflowing then
					-- Draw/process horizontal scroller

					if xOverflowing and hScrollPossible then
						processScroll(
							theme,
							ui.HORIZONTAL,
							state.scroll,
							dctx,
							pos,
							innerSize,
							contentSize,
							hScrollThickness
						)
					end
					
					-- Draw/process vertical scroller
					
					if yOverflowing and vScrollPossible then
						processScroll(
							theme,
							ui.VERTICAL,
							state.scroll,
							dctx,
							pos,
							innerSize,
							contentSize,
							vScrollThickness
						)
					end

					-- Make everything below draw into the buffer
					buffer = dctx.claimBuffer(
						innerSize.X,
						innerSize.Y
					):push(pos)
				end

				local drawOffset
				if overflowing then
					if axis == ui.HORIZONTAL then
						drawOffset = vec2(-state.scroll.offset, 0)
					else
						drawOffset = vec2(0, -state.scroll.offset)
					end
				else
					drawOffset = pos
				end

				local crossSize
				if axis == ui.HORIZONTAL then
					crossSize = size.Y
				else
				  crossSize = size.X	
				end
				
				local mainOffset = 0
				local crossOffset = 0
				
				for i = 1, #results do
					local result = results[i]
					
					local main, cross
					if axis == ui.HORIZONTAL then
						main = result.size.X
						cross = result.size.Y
					else
						main = result.size.Y
						cross = result.size.X	
					end
					
					if alignment == ui.START then
						crossOffset = 0
					elseif alignment == ui.MIDDLE then
						crossOffset = crossSize / 2 - cross / 2
					elseif alignment == ui.END then
						crossOffset = crossSize - cross
					end
					
					local xOffset, yOffset
					if axis == ui.HORIZONTAL then
						xOffset = mainOffset
						yOffset = crossOffset
					else
						yOffset = mainOffset
						xOffset = crossOffset	
					end
					
					local drawPos = drawOffset + vec2(xOffset, yOffset)
					
					if not overflowing or rectOnScreen(drawPos, result.size, innerSize) then
						result.draw(
							drawPos,
							dctx
						)
					end
					
					mainOffset = mainOffset + main + gap
				end

				if buffer then
					buffer:pop():draw().release()
				end
			end
		}
	end
end

export type ProgressStyle = {
	height: number,
	minWidth: number,
	color: color,
	layout: (self: ProgressStyle, expand: boolean, progress: number) -> LayoutFunc
}

function ui.progress(theme: Theme): ProgressStyle
	local char = theme.defaultFont:GetSpritePixelData(0, 0)
	
	return {
		height = char.Height - 1,
		minWidth = 50,
		color = theme.activeBG,
		layout = function(self, expand, progress)
			return function(ctx)
				local size
				if expand then
					size = vec2(
						ctx.max.X, self.height
					)
				else
					size = vec2(
						math.max(self.minWidth, ctx.min.X),
						self.height
					)
				end
				
				return {
					size = size,
					draw = function(pos, dctx)
						local pSize = vec2(
							size.X * clamp01(progress),
							size.Y
						)
						local pEnd = rectEnd(pos, pSize)
						local lEnd = rectEnd(pos, size)
					
						dctx.video:DrawLine(
							vec2(
								pos.X, 
								lEnd.Y
							),
							lEnd,
							self.color
						)
						dctx.video:FillRect(
							pos,
							pEnd,
							self.color
						)
					end
				}
			end
		end
	}
end

return ui
