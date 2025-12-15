-- server/main.lua
local resourceName = GetCurrentResourceName()
local root = GetResourcePath(resourceName)
local storagePath = root .. "/recordings/" --make sure this folder exists and that the server is allowed to write there!!

-- in-memory cache
local recordings = {}

-- load recordings from file
local function loadRecordings()
    --clear existing
    recordings = {}
    for file in io.popen('dir "'..storagePath..'" /b'):lines() do
        if file:sub(-4) == ".bin" then
            --load file
            local startTime = GetGameTimer()
            local content = LoadResourceFile(resourceName, "recordings/" .. file)
            --unpack msgpack
            local ok, data = pcall(function() return msgpack.unpack(content) end)
            if ok and data then
                local name = file:sub(1, -5)  -- remove .bin
                recordings[name] = data
                print(('[GhostReplay] 🗄️ Loaded recording %s from file (%d bytes msgpack) in %d ms'):format(name, #content, GetGameTimer() - startTime))
            else
                print(('[GhostReplay] ❌ Failed to unpack recording from file: %s'):format(file))
            end
        end
    end
    print(('^3[GhostReplay]^0 ℹ️ Loaded recordings into cache from files'):format())
end

-- helper: count table entries
function table.count(t)
    local c = 0
    for _ in pairs(t) do c = c + 1 end
    return c
end

-- save all recordings to file
local function saveRecordings()
    for name, rec in pairs(recordings) do
        local packed = msgpack.pack(rec)
        local ok, err = pcall(function()
            SaveResourceFile(resourceName, "recordings/" .. name .. ".bin", packed, #packed)
        end)
        if not ok then
            print(('[GhostReplay] ❌ Failed to save recording %s to file: %s'):format(name, err))
        end
    end
end

-- event: save recording
RegisterNetEvent("ghost:saveRecording")
AddEventHandler("ghost:saveRecording", function(name, data)
    local _src = source
    if not name or name == "" then
        name = ("ghost_%d"):format(os.time())
    end

    local pName = GetPlayerName(_src)
    data.recorder = pName

    -- overwrite if same name exists
    recordings[name] = {
        name = name,
        recorder = pName,
        data = data
    }

    saveRecordings()

    print(('[GhostReplay] ✅ Stored "%s" by %s (total now %d)'):format(name, pName, table.count(recordings)))
    TriggerClientEvent("ghost:saveResult", _src, true, name)
end)

-- event: request recording
RegisterNetEvent("ghost:requestRecording")
AddEventHandler("ghost:requestRecording", function(name)
    local _src = source
    if not name or name == "" then
        TriggerClientEvent("ghost:requestResult", _src, false, name, "No name provided")
        return
    end

    local rec = recordings[name]
    if rec then
        TriggerLatentClientEvent("ghost:play", _src, 75000, rec.data, name)
        print(('[GhostReplay] ▶️ Sent "%s" to player %d'):format(name, _src))
    else
        --try to load from file
        local content = LoadResourceFile(resourceName, "recordings/" .. name .. ".bin")
        if not content then
            TriggerClientEvent("ghost:requestResult", _src, false, name, "Recording not found")
            --print(('[GhostReplay] ❌ Recording %s not found for player %d'):format(name, _src))
            return
        end
        local ok, data = pcall(function() return msgpack.unpack(content) end)
        if not ok or not data then
            TriggerClientEvent("ghost:requestResult", _src, false, name, "Failed to unpack recording")
            print(('[GhostReplay] ❌ Failed to unpack recording %s for player %d'):format(name, _src))
            return
        end
        recordings[name] = data  -- cache in memory
        TriggerLatentClientEvent("ghost:play", _src, 200000, data, name)
    end
end)

-- event: list recordings
RegisterNetEvent("ghost:listRecordings")
AddEventHandler("ghost:listRecordings", function()
    local _src = source
    local names = {}
    for k in pairs(recordings) do
        table.insert(names, k)
    end
    TriggerClientEvent("ghost:sendList", _src, names)
end)

-- command/event: delete all
function DeleteAllRecordings()
    recordings = {}
    saveRecordings()
    print("[GhostReplay] 🗑️ Deleted all recordings")
end

-- load on resource start
loadRecordings()
