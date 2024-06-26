Engine = require "engine"
Perspective = require "perspective"
require "tiledata"
require "things"
require "player"
require "generator"
require "lighting"
require "chunk"
require "caves"

function love.load()
    -- window graphics settings
    GraphicsWidth, GraphicsHeight = 1280,720--520*2, (520*9/16)*2
    InterfaceWidth, InterfaceHeight = GraphicsWidth, GraphicsHeight
    love.graphics.setBackgroundColor(0,0.7,0.95)
    love.mouse.setRelativeMode(true)
    love.graphics.setDefaultFilter("nearest", "nearest")
    love.graphics.setLineStyle("rough")
    love.window.setMode(GraphicsWidth,GraphicsHeight, {vsync = -1})
    love.window.setTitle("Block World - Test Mode")

    -- for capping game logic at 60 manually
    LogicRate = 60
    LogicAccumulator = 0
    PhysicsStep = true

    -- load assets
    DefaultTexture = love.graphics.newImage("assets/texture.png")
    TileTexture = love.graphics.newImage("assets/terrain.png")
    GuiSprites = love.graphics.newImage("assets/gui.png")
    GuiHotbarQuad = love.graphics.newQuad(0,0, 182,22, GuiSprites:getDimensions())
    GuiHotbarSelectQuad = love.graphics.newQuad(0,22, 24,22+24, GuiSprites:getDimensions())
    GuiCrosshair = love.graphics.newQuad(256-16,0, 256,16, GuiSprites:getDimensions())
	
	start()
end

function start()
    -- shader to change color of crosshair to contrast (hopefully) with what is being looked at
    CrosshairShader = love.graphics.newShader[[
        uniform Image source;
        uniform number xProportion;
        uniform number yProportion;

        vec4 effect(vec4 color, Image texture, vec2 texture_coords, vec2 screen_coords)
        {
            vec2 scaled_coords = vec2(0,0);
            scaled_coords.x = (texture_coords.x-0.9375)*16;
            scaled_coords.y = (texture_coords.y)*16;
            vec4 sourcecolor = Texel(source, vec2(0.5 + (-0.5 +scaled_coords.x)*xProportion,0.5 + (0.5 -scaled_coords.y)*yProportion));

            sourcecolor.r = 1-sourcecolor.r;
            sourcecolor.g = 1-sourcecolor.g;
            sourcecolor.b = 1-sourcecolor.b;

            sourcecolor.a = 1;
            vec4 crosshair = Texel(texture, texture_coords);
            sourcecolor.a = crosshair.a;

            return sourcecolor;
        }
    ]]

    -- make a separate canvas image for each of the tiles in the TileTexture
    TileCanvas = {}
    for i=1, 16 do
        for j=1, 16 do
            local xx,yy = (i-1)*16,(j-1)*16
            local index = (j-1)*16 + i
            TileCanvas[index] = love.graphics.newCanvas(16,16)
            local this = TileCanvas[index]
            love.graphics.setCanvas(this)
            love.graphics.draw(TileTexture, -1*xx,-1*yy)
        end
    end
    love.graphics.setCanvas()

    -- create lighting value textures on LightingTexture canvas
    LightValues = 16
    local width, height = TileTexture:getWidth(), TileTexture:getHeight()
    LightingTexture = love.graphics.newCanvas(width*LightValues, height)
    local mult = 1
    love.graphics.setCanvas(LightingTexture)
    love.graphics.clear(1,1,1,0)
    for i=LightValues, 1, -1 do
        local xx = (i-1)*width
        love.graphics.setColor(mult,mult,mult)
        love.graphics.draw(TileTexture, xx,0)
        mult = mult * 0.8
    end
    love.graphics.setColor(1,1,1)
    love.graphics.setCanvas()

    -- global variables used in world generation
    ChunkSize = 16
    SliceHeight = 8
    WorldHeight = 128
    TileWidth, TileHeight = 1/16,1/16
    TileDataSize = 3

    GenerateWorld()
end

function GenerateWorld()
    -- create scene object from SS3D engine
    Scene = Engine.newScene(GraphicsWidth, GraphicsHeight)
    Scene.camera.perspective = TransposeMatrix(cpml.mat4.from_perspective(90, love.graphics.getWidth()/love.graphics.getHeight(), 0.001, 10000))

    -- global random numbers used for generation
    Salt = {}
    for i=1, 128 do
        Salt[i] = love.math.random()
    end

    -- initializing the update queue that holds all entities
    ThingList = {}
    ThePlayer = CreateThing(NewPlayer(0,128,0))
    PlayerInventory = {items = {}, hotbarSelect=1}

    for i=1, 36 do
        PlayerInventory.items[i] = 0
    end
    PlayerInventory.items[1] = 2
    PlayerInventory.items[2] = 3
    PlayerInventory.items[3] = 1
    PlayerInventory.items[4] = 5
    PlayerInventory.items[5] = 13
    PlayerInventory.items[6] = 12
    PlayerInventory.items[7] = 18
    PlayerInventory.items[8] = 20
    PlayerInventory.items[9] = 0

    -- generate the world, store in 2d hash table
    ChunkHashTable = {}
    ChunkList = {}
    ChunkRequests = {}
    LightingQueue = {}
    LightingRemovalQueue = {}
    CaveList = {}
    local worldSize = 4

    StartTime = love.timer.getTime()
    MeasureTime = StartTime
    local timeDiff = function ()
        local timeget = love.timer.getTime()
        local ret = timeget - MeasureTime
        MeasureTime = timeget

        return ret
    end

    for i=worldSize/-2 +1, worldSize/2 do
        ChunkHashTable[ChunkHash(i)] = {}
        for j=worldSize/-2 +1, worldSize/2 do
            ChunkList[#ChunkList+1] = NewChunk(i,j)
            ChunkHashTable[ChunkHash(i)][ChunkHash(j)] = ChunkList[#ChunkList]
        end
    end
    print("terrain: " .. timeDiff())

    UpdateCaves()
    LightingUpdate()
    print("caves: " .. timeDiff())

    for i=1, #ChunkList do
        ChunkList[i]:sunlight()
    end
    print("queueSize: " .. #LightingQueue)
    LightingUpdate()
    print("lighting: " .. timeDiff())

    for i=1, #ChunkList do
        ChunkList[i]:populate()
    end
    print("populating: " .. timeDiff())

    for i=1, #ChunkList do
        ChunkList[i]:processRequests()
    end
    print("queueSize: " .. #LightingRemovalQueue)
    print("processing requests: " .. timeDiff())

    for i=1, #ChunkList do
        ChunkList[i]:initialize()
    end
    print("modelling: " .. timeDiff())

    print("total generation time: " .. (love.timer.getTime() - StartTime))
end

-- convert an index into a point on a 2d plane of given width and height
function NumberToCoord(n, w,h)
    local y = math.floor(n/w)
    local x = n-(y*w)

    return x,y
end

-- hash function used in chunk hash table
function ChunkHash(x)
    if x < 0 then
        return math.abs(2*x)
    end

    return 1 + 2*x
end

function Localize(x,y,z)
    return x%ChunkSize +1, y, z%ChunkSize +1
end
function Globalize(cx,cz, x,y,z)
    return (cx-1)*ChunkSize + x-1, y, (cz-1)*ChunkSize + z-1
end

function ToChunkCoords(x,z)
    return math.floor(x/ChunkSize)+1, math.floor(z/ChunkSize)+1
end

-- get chunk from reading chunk hash table at given position
function GetChunk(x,y,z)
    local x = math.floor(x)
    local y = math.floor(y)
    local z = math.floor(z)
    local hashx,hashy = ChunkHash(math.floor(x/ChunkSize)+1), ChunkHash(math.floor(z/ChunkSize)+1)
    local getChunk = nil
    if ChunkHashTable[hashx] ~= nil then
        getChunk = ChunkHashTable[hashx][hashy]
    end
    if y < 1 or y > WorldHeight then
        getChunk = nil
    end

    local mx,mz = x%ChunkSize +1, z%ChunkSize +1

    return getChunk, mx,y,mz, hashx,hashy
end

function GetChunkRaw(x,z)
    local hashx,hashy = ChunkHash(x), ChunkHash(z)
    local getChunk = nil
    if ChunkHashTable[hashx] ~= nil then
        getChunk = ChunkHashTable[hashx][hashy]
    end

    return getChunk
end

-- get voxel by looking at chunk at given position's local coordinate system
function GetVoxel(x,y,z)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    local v = 0
    if chunk ~= nil then
        v = chunk:getVoxel(cx,cy,cz)
    end
    return v
end
function GetVoxelData(x,y,z)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    local v = 0
    local d = 0
    if chunk ~= nil then
        v, d = chunk:getVoxel(cx,cy,cz)
    end
    return d
end

function GetVoxelFirstData(x,y,z)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    if chunk ~= nil then
        return chunk:getVoxelFirstData(cx,cy,cz)
    end
    return 0
end

function GetVoxelSecondData(x,y,z)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    if chunk ~= nil then
        return chunk:getVoxelSecondData(cx,cy,cz)
    end
    return 0
end

function SetVoxel(x,y,z, value)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    if chunk ~= nil then
        chunk:setVoxel(cx,cy,cz, value)
        return true
    end
    return false
end
function SetVoxelData(x,y,z, value)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    if chunk ~= nil then
        chunk:setVoxelData(cx,cy,cz, value)
        return true
    end
    return false
end

function SetVoxelFirstData(x,y,z, value)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    if chunk ~= nil then
        chunk:setVoxelFirstData(cx,cy,cz, value)
        return true
    end
    return false
end
function SetVoxelSecondData(x,y,z, value)
    local chunk, cx,cy,cz = GetChunk(x,y,z)
    if chunk ~= nil then
        chunk:setVoxelSecondData(cx,cy,cz, value)
        return true
    end
    return false
end

function UpdateChangedChunks()
    for i=1, #ChunkList do
        if #ChunkList[i].changes > 0 then
            ChunkList[i]:updateModel()
        end
    end
end

function love.update(dt)
    LogicAccumulator = LogicAccumulator+dt

    -- update 3d scene
    Scene:update()
    PhysicsStep = false
    if LogicAccumulator >= 1/LogicRate then
        LogicAccumulator = LogicAccumulator - 1/LogicRate
        PhysicsStep = true
    end

    -- update all things in ThingList update queue
    local i = 1
    while i<=#ThingList do
        local thing = ThingList[i]
        if thing:update(dt) then
            i=i+1
        else
            table.remove(ThingList, i)
            thing:destroy()
            thing:destroyModel()
        end
    end
end

function DrawHudTile(tile, x,y)
    -- weirdly returning one index arrays as raw numbers
    -- check for that
    local textures = TileTextures(tile)

    if tile == 0 or textures == nil then
        return
    end
    local x,y = x+16+6,y+16+6
    local size = 16
    local xsize = math.sin(3.14159/3)*16
    local ysize = math.cos(3.14159/3)*16
    love.graphics.setColor(1,1,1)

    local centerPoint = {x,y}

    -- textures are in format: SIDE UP DOWN FRONT
    -- top
    Perspective.quad(TileCanvas[textures[math.min(#textures, 2)]+1], {x,y-size},{x +xsize,y-ysize},centerPoint,{x-xsize,y-ysize})

    -- right side front
    local shade1 = 0.8^3
    love.graphics.setColor(shade1,shade1,shade1)
    local index = 1
    if #textures == 4 then
        index = 4
    end
    Perspective.quad(TileCanvas[textures[index]+1], centerPoint,{x +xsize,y -ysize},{x+xsize,y+ysize},{x,y+size})

    -- left side side
    local shade2 = 0.8^2
    love.graphics.setColor(shade2,shade2,shade2)
    Perspective.flip = true
    Perspective.quad(TileCanvas[textures[1]+1], centerPoint,{x -xsize,y -ysize},{x-xsize,y+ysize},{x,y+size})
    Perspective.flip = false
end

function love.draw()
    -- draw 3d scene
    Scene:render(true)

    -- draw HUD
    Scene:renderFunction(
        function ()
            love.graphics.setColor(0,0,0)
            love.graphics.print("x: "..math.floor(ThePlayer.x+0.5).."\ny: "..math.floor(ThePlayer.y+0.5).."\nz: "..math.floor(ThePlayer.z+0.5))
			
            local chunk, cx,cy,cz, hashx,hashy = GetChunk(ThePlayer.x,ThePlayer.y,ThePlayer.z)
            if chunk ~= nil then
                love.graphics.print("kB: "..math.floor(collectgarbage('count')),0,50)
            end
            love.graphics.print("FPS: "..love.timer.getFPS(), 0, 70)
            love.graphics.print("#LightingQueue: "..#LightingQueue, 0, 90)
            love.graphics.print("#LightingRQueue: "..#LightingRemovalQueue, 0, 110)
            -- love.graphics.print("Press 'V' to toggle VSync", 0, 90)
            -- love.graphics.print("#ThingList: "..#ThingList, 0, 90)
            --[[for i=1, #ThingList do
                love.graphics.print(ThingList[i].name, 10, 100+i*15)
            end]]--

            -- draw crosshair
            love.graphics.setColor(1,1,1)
            CrosshairShader:send("source", Scene.threeCanvas)
            CrosshairShader:send("xProportion", 32/GraphicsWidth)
            CrosshairShader:send("yProportion", 32/GraphicsHeight)
            love.graphics.setShader(CrosshairShader)
            love.graphics.draw(GuiSprites, GuiCrosshair, InterfaceWidth/2 -16,InterfaceHeight/2 -16, 0, 2,2)
            love.graphics.setShader()

            -- draw hotbar
            love.graphics.setColor(1,1,1)
            love.graphics.draw(GuiSprites, GuiHotbarQuad, InterfaceWidth/2 - 182, InterfaceHeight-22*2, 0, 2,2)
            love.graphics.draw(GuiSprites, GuiHotbarSelectQuad, InterfaceWidth/2 - 182 + 40*(PlayerInventory.hotbarSelect-1) -2, InterfaceHeight-24 -22, 0, 2,2)

            for i=1, 9 do
                DrawHudTile(PlayerInventory.items[i], InterfaceWidth/2 -182 +40*(i-1),InterfaceHeight-22*2)
            end
        end, false
    )

    love.graphics.setColor(1,1,1)
    local scale = love.graphics.getWidth()/InterfaceWidth
    love.graphics.draw(Scene.twoCanvas, love.graphics.getWidth()/2,love.graphics.getHeight()/2 +1, 0, scale,scale, InterfaceWidth/2, InterfaceHeight/2)
end

function love.mousemoved(x,y, dx,dy)
    -- forward mouselook to Scene object for first person camera control
    Scene:mouseLook(x/5,y/5, dx/5,dy/5)
end

function love.wheelmoved(x,y)
    PlayerInventory.hotbarSelect = math.floor( ((PlayerInventory.hotbarSelect - y -1)%9 +1) +0.5)
end

function love.mousepressed(x,y, b)
    -- forward mousepress events to all things in ThingList
    for i=1, #ThingList do
        local thing = ThingList[i]
        thing:mousepressed(b)
    end

    -- handle clicking to place / destroy blocks
    local pos = ThePlayer.cursorpos
    local value = 0

    if b == 2 then
        pos = ThePlayer.cursorposPrev
        value = PlayerInventory.items[PlayerInventory.hotbarSelect]
    end

    local cx,cy,cz = pos.x, pos.y, pos.z
    local chunk = pos.chunk
    if chunk ~= nil and ThePlayer.cursorpos.chunk ~= nil and ThePlayer.cursorHit then
        chunk:setVoxel(cx,cy,cz, value,true)
        LightingUpdate()
        UpdateChangedChunks()
        --chunk:updateModel(cx,cy,cz)
        --print("---")
        --print(cx,cy,cz)
        --print(cx%ChunkSize,cy%SliceHeight,cz%ChunkSize)
    end
end

function love.keypressed(k)
    if k == "escape" then
        love.event.push("quit")
    end

    if k == "n" then -- or ThePlayer.y+.5 >= -50 then
        GenerateWorld()
    end

    -- simplified hotbar number press code, thanks nico-abram!
    local numberPress = tonumber(k)
    if numberPress ~= nil and numberPress >= 1 and numberPress <= 9 then
        PlayerInventory.hotbarSelect = numberPress
    end
end

function lerp(a,b,t) return (1-t)*a + t*b end
function math.angle(x1,y1, x2,y2) return math.atan2(y2-y1, x2-x1) end
function math.dist(x1,y1, x2,y2) return ((x2-x1)^2+(y2-y1)^2)^0.5 end
function math.dist3d(x1,y1,z1, x2,y2,z2) return ((x2-x1)^2+(y2-y1)^2+(z2-z1)^2)^0.5 end

function choose(arr)
    return arr[math.floor(love.math.random()*(#arr))+1]
end
function rand(min,max, interval)
    local interval = interval or 1
    local c = {}
    local index = 1
    for i=min, max, interval do
        c[index] = i
        index = index + 1
    end

    return choose(c)
end

function table_print (tt, indent, done)
  done = done or {}
  indent = indent or 0
  if type(tt) == "table" then
    local sb = {}
    for key, value in pairs (tt) do
      table.insert(sb, string.rep (" ", indent)) -- indent it
      if type (value) == "table" and not done [value] then
        done [value] = true
        table.insert(sb, key .. " = {\n");
        table.insert(sb, table_print (value, indent + 2, done))
        table.insert(sb, string.rep (" ", indent)) -- indent it
        table.insert(sb, "}\n");
      elseif "number" == type(key) then
        table.insert(sb, string.format("\"%s\"\n", tostring(value)))
      else
        table.insert(sb, string.format(
            "%s = \"%s\"\n", tostring (key), tostring(value)))
       end
    end
    return table.concat(sb)
  else
    return tt .. "\n"
  end
end

function to_string( tbl )
    if  "nil"       == type( tbl ) then
        return tostring(nil)
    elseif  "table" == type( tbl ) then
        return table_print(tbl)
    elseif  "string" == type( tbl ) then
        return tbl
    else
        return tostring(tbl)
    end
end