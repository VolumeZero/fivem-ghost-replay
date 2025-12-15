-- client/main.lua
local recording = false
local recordData = {}
local recordStart = 0
local recordTickMs = 50 -- 20 Hz
local lastTick = 0

-- interpolation helper
local function lerp(a, b, t) return a + (b - a) * t end
local function lerpVec(a, b, t)
    return vector3(
        lerp(a.x, b.x, t),
        lerp(a.y, b.y, t),
        lerp(a.z, b.z, t)
    )
end

-- get vehicle state
local function getVehicleState(veh, t)
    local pos = GetEntityCoords(veh, false)
    local rot = GetEntityRotation(veh, 2) -- degrees
    return {
        t = t,
        pos = vec3(pos.x, pos.y, pos.z),
        rot = vec3(rot.x, rot.y, rot.z),
    }
end


-- Start/Stop recording
RegisterCommand('ghostrecord', function(source, args)
    local sub = args[1]
    if not sub or sub == 'start' then
        if recording then
            TriggerEvent('chat:addMessage', { args = { '^1Ghost', 'Already recording.' } })
            return
        end
        local ped = PlayerPedId()
        if not IsPedInAnyVehicle(ped, false) then
            TriggerEvent('chat:addMessage', { args = { '^1Ghost', 'You must be in a vehicle to record.' } })
            return
        end
        local veh = GetVehiclePedIsIn(ped, false)
        recordData = {}
        recordData.model = GetEntityModel(veh)
        recordStart = GetGameTimer()
        recording = true
        lastTick = 0
        TriggerEvent('chat:addMessage', { args = { '^2Ghost', 'Recording started.' } })
    elseif sub == 'stop' then
        if not recording then
            TriggerEvent('chat:addMessage', { args = { '^1Ghost', 'Not recording.' } })
            return
        end
        local name = args[2]
        if not name or name == '' then
            name = ('ghost_%d'):format(math.floor(GetGameTimer()/1000))
        end
        recording = false
        -- send to server
        TriggerServerEvent('ghost:saveRecording', name, recordData)
    else
        TriggerEvent('chat:addMessage', { args = { '^3Ghost', 'Usage: /ghostrecord start | stop <name>' } })
    end
end)

RegisterCommand('ghostplay', function(_, args)
    local name = args[1]
    if not name or name == '' then
        TriggerEvent('chat:addMessage', { args = { '^3Ghost', 'Usage: /ghostplay <name>' } })
        return
    end
    TriggerServerEvent('ghost:requestRecording', name)
end)

RegisterCommand('ghostlist', function()
    TriggerServerEvent('ghost:listRecordings')
end)

-- receive list
RegisterNetEvent('ghost:sendList')
AddEventHandler('ghost:sendList', function(list)
    TriggerEvent('chat:addMessage', { args = { '^3Ghost', 'Saved recordings:' } })
    for i, v in ipairs(list) do
        TriggerEvent('chat:addMessage', { args = { '^7- ' .. v } })
    end
end)

-- server sends recording JSON table
RegisterNetEvent('ghost:play')
AddEventHandler('ghost:play', function(rec)
    if not rec or #rec < 2 then
        TriggerEvent('chat:addMessage', { args = { '^1Ghost', 'Recording is empty or not found.' } })
        return
    end

    Citizen.CreateThread(function()
        -- spawn ghost vehicle at first state's pos with same model
        local first = rec[1]
        local model = rec.model or first.model
        if not model then model = GetHashKey('adder') end
        local modelHash = model
        if type(modelHash) ~= 'number' then modelHash = GetHashKey(model) end

        RequestModel(modelHash)
        local try = 0
        while not HasModelLoaded(modelHash) and try < 100 do
            Citizen.Wait(50); try = try + 1
        end
        if not HasModelLoaded(modelHash) then
            TriggerEvent('chat:addMessage', { args = { '^1Ghost', 'Failed to load vehicle model.' } })
            return
        end

        TriggerEvent('chat:addMessage', { args = { '^2Ghost', 'Playing recording...' } })

        local spawnPos = vector3(first.pos.x, first.pos.y, first.pos.z)
        local ghostVeh = CreateVehicle(modelHash, spawnPos.x, spawnPos.y, spawnPos.z + 1.0, first.rot.z or 0.0, false, false)
        SetEntityInvincible(ghostVeh, true)
        SetEntityCollision(ghostVeh, false, false)
        SetVehicleColours(ghostVeh, 0, 0)
        SetVehicleDirtLevel(ghostVeh, 0.0)
        SetEntityAlpha(ghostVeh, 140, false) -- semi-transparent
        SetEntityAsMissionEntity(ghostVeh, true, true)

        local startTime = GetGameTimer()
        local totalDuration = (rec[#rec].t - rec[1].t) / 1000.0

        -- playback loop
        while true do
            local elapsed = (GetGameTimer() - startTime) / 1000.0
            if elapsed > totalDuration then break end

            -- find frames
            -- convert elapsed back into ms offset from rec[1].t
            local targetMs = rec[1].t + (elapsed * 1000.0)
            -- find index i such that rec[i].t <= targetMs <= rec[i+1].t
            local i = 1
            while i < #rec and rec[i+1].t < targetMs do i = i + 1 end
            local a = rec[i]
            local b = rec[math.min(i+1, #rec)]
            local span = math.max(1, (b.t - a.t))
            local t = 0
            if b.t ~= a.t then t = (targetMs - a.t) / (b.t - a.t) end

            -- interpolate
            local apos = vector3(a.pos.x, a.pos.y, a.pos.z)
            local bpos = vector3(b.pos.x, b.pos.y, b.pos.z)
            local arot = vector3(a.rot.x, a.rot.y, a.rot.z)
            local brot = vector3(b.rot.x, b.rot.y, b.rot.z)

            local newPos = lerpVec(apos, bpos, t)
            local newRot = lerpVec(arot, brot, t)

            -- set coords & rotation
            SetEntityCoordsNoOffset(ghostVeh, newPos.x, newPos.y, newPos.z, false, false, false)
            SetEntityRotation(ghostVeh, newRot.x, newRot.y, newRot.z, 2, true)

            Citizen.Wait(0)
        end

        -- ensure final frame
        local last = rec[#rec]
        SetEntityCoordsNoOffset(ghostVeh, last.pos.x, last.pos.y, last.pos.z, false, false, false)
        SetEntityRotation(ghostVeh, last.rot.x, last.rot.y, last.rot.z, 2, true)

        -- cleanup
        Citizen.Wait(250)
        SetEntityAsNoLongerNeeded(ghostVeh)
        DeleteEntity(ghostVeh)
    end)
end)

-- receive save result
RegisterNetEvent('ghost:saveResult')
AddEventHandler('ghost:saveResult', function(ok, name, msg)
    if ok then
        TriggerEvent('chat:addMessage', { args = { '^2Ghost', 'Saved recording: ' .. name } })
    else
        TriggerEvent('chat:addMessage', { args = { '^1Ghost', 'Failed to save: ' .. tostring(msg) } })
    end
end)

-- Recording loop
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if recording then
            local now = GetGameTimer()
            if now - lastTick >= recordTickMs then
                lastTick = now
                local ped = PlayerPedId()
                if not IsPedInAnyVehicle(ped, false) then
                    -- stopped being in vehicle => automatically stop recording
                    recording = false
                    TriggerServerEvent('ghost:saveRecording', ('ghost_%d'):format(math.floor(recordStart/1000)), recordData)
                    TriggerEvent('chat:addMessage', { args = { '^2Ghost', 'Stopped recording (you left the vehicle).' } })
                else
                    local veh = GetVehiclePedIsIn(ped, false)
                    local offset = now - recordStart
                    local s = getVehicleState(veh, offset)
                    table.insert(recordData, s)
                end
            end
        else
            Citizen.Wait(200)
        end
    end
end)
