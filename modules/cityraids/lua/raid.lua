-----------------------------------
-- City Raids
-----------------------------------
require('modules/module_utils')
require('scripts/globals/npc_util')
require('scripts/globals/mobs')
require('scripts/globals/pathfind')
require('scripts/utils/utils')
require('modules/cityraids/lua/raid_data')
-----------------------------------
xi = xi or {}
xi.raid = xi.raid or {}

local m = Module:new('city_raids')

local enableDebugPrints = false

local nationName =
{
    [xi.nation.SANDORIA] = 'San d\'Oria',
    [xi.nation.BASTOK  ] = 'Bastok',
    [xi.nation.WINDURST] = 'Windurst',
    [xi.nation.BEASTMEN] = 'Beastmen',
    [xi.nation.OTHER   ] = 'Other',
}

-----------------------------------
-- Debug Utilities.
-----------------------------------

-- Prints the given message if DEBUG_GARRISON is enabled
local function debugLog(msg)
    if enableDebugPrints then
        print('[Raid]: ' .. msg)
    end
end

-- Prints the given message with printf if DEBUG_GARRISON is enabled
local function debugLogf(msg, ...)
    if enableDebugPrints then
        printf('[Raid]: ' .. msg, ...)
    end
end

-- Shows the given server message to all players if DEBUG_GARRISON is enabled
local function debugPrintToPlayers(players, msg)
    if enableDebugPrints then
        for _, player in pairs(players) do
            player:printToPlayer(msg)
        end
    end
end

-----------------------------------
-- Local Utilities.
-----------------------------------

-- Sends a message packet to all players
local function messagePlayers(npc, players, msg)
    for _, player in ipairs(players) do
        player:messageText(npc, msg)
    end
end

local function messagePlayersPrint(players, msg)
    for _, player in ipairs(players) do
        player:printToPlayer(msg, xi.msg.channel.NS_SAY)
    end
end

-- Utility function to get the number of parties in the player's alliance.
local function getNumPartiesInAlliance(player)
    local alliance   = player:getAlliance()
    local numLeaders = 0
    local leaders    = {}

    for _, member in pairs(alliance) do
        local leader = member:getPartyLeader()

        if leader ~= nil and not leaders[leader:getName()] then
            numLeaders = numLeaders + 1
            leaders[leader:getName()] = true
        end
    end

    return numLeaders
end

-----------------------------------
-- Global Utilities.
-----------------------------------

-- Add level restriction effect
-- If a party member is KO'd during the Raid, they're out.
-- Giving this the CONFRONTATION flag hooks into the target validation system and stops outsiders participating, for mobs, allies, and players.
xi.raid.addLevelCap = function(entity, definedCap)
    local cap = definedCap

    -- If this Raid is uncapped, use the server max.
    if definedCap == 99 then
        cap = xi.settings.main.MAX_LEVEL
    end

    -- Note the level restriction does not wear on death.
    entity:addStatusEffectEx(xi.effect.LEVEL_RESTRICTION, xi.effect.LEVEL_RESTRICTION, cap, 0, 0, 0, 0, 0, xi.effectFlag.ON_ZONE + xi.effectFlag.CONFRONTATION)
end

-----------------------------------
-- Raid NPC Ally handling.
-----------------------------------

xi.raid.rollNPCs = function(zone, zoneData)
    local dTableNPCs = {}

    debugLogf('Spawning %d npcs. GroupId: %d', 5, zoneData.allyGroupId)

    for i = 1, 5 do
        table.insert(dTableNPCs, {
            name = utils.randomEntry(zoneData.allyNames),
            look = utils.randomEntry(zoneData.allyLooks),
            pos  = zoneData.allyPos[i],
            groupId = zoneData.allyGroupId,
        })
    end

    return dTableNPCs
end

-- Spawns and npc for the given zone and with the given name, look, pose. Uses dynamic entities
xi.raid.spawnNPC = function(zone, zoneData, pos, name, groupId, look)
    local mob = zone:insertDynamicEntity({
        objtype               = xi.objType.MOB,
        allegiance            = xi.allegiance.PLAYER,
        name                  = name,
        x                     = zoneData.allyPrepPos[1],
        y                     = zoneData.allyPrepPos[2],
        z                     = zoneData.allyPrepPos[3],
        rotation              = zoneData.allyPrepPos[4],
        look                  = look,
        groupId               = groupId,
        groupZoneId           = xi.zone.GM_HOME,
        releaseIdOnDisappear  = true,
        specialSpawnAnimation = true,
    })

    debugLogf('NPC: %s (%d), Level: %d, HP: %d', mob:getName(), mob:getID(), mob:getMainLvl(), mob:getHP())

    -- Use the mob object as you normally would
    mob:setRoamFlags(xi.roamFlag.SCRIPTED)
    mob:setSpawn(zoneData.allyPrepPos[1], zoneData.allyPrepPos[2], zoneData.allyPrepPos[3], zoneData.allyPrepPos[4])

    mob:spawn()

    DisallowRespawn(mob:getID(), true)
    mob:setBaseSpeed(25)
	mob:setMobMod(xi.mobMod.NO_DROPS, 1)
	mob:setMobMod(xi.mobMod.NO_DESPAWN, 1)
    mob:setMobMod(xi.mobMod.ROAM_DISTANCE, 100)

    -- Death listener for tracking win/lose condition
    mob:addListener('DEATH', 'RAID_NPC_DEATH', function(mobArg)
         zoneData.deadNPCCount = zoneData.deadNPCCount + 1

         if #zoneData.players > 0 then
            for _, playerId in ipairs(zoneData.players) do
                local player = GetPlayerByID(playerId)
                if player ~= nil then
                    player:printToPlayer(utils.randomEntry(zoneData.allyDeathSay), xi.msg.channel.SAY, mob:getPacketName())
                end
            end
        end
        table.remove(zoneData.npcs, mob:getID())
    end)

    mob:addListener('ENGAGE', 'RAID_NPC_ENGAGE', function(mobArg)
        if math.random(1, 100) <= 20 then
            if #zoneData.players > 0 then
                for _, playerId in ipairs(zoneData.players) do
                    local player = GetPlayerByID(playerId)
                    if player ~= nil then
                        player:printToPlayer(utils.randomEntry(zoneData.allySay), xi.msg.channel.SAY, mob:getPacketName())
                    end
                end
            end
        end
    end)

    mob:addListener('DISENGAGE', 'RAID_NPC_DISENGAGE', function(mobArg)
        if #zoneData.mobs > 0 then
            xi.raid.aggroGroups({ mob:getID() }, zoneData.mobs)
        end
    end)

    mob:setPos(pos[1], pos[2], pos[3], pos[4])
    mob:setSpawn(pos[1], pos[2], pos[3], pos[4])
    return mob
end

-- Spawns all npcs for the zone in the given raid starting npc
xi.raid.spawnNPCs = function(zone, zoneData)
    local zoneID   = zone:getID()

    -- Spawn 1 npc per player in alliance
    local npcs = xi.raid.rollNPCs(zone, zoneData)

    if #npcs == 0 then
        debugLogf('No NPC allies rolled. Unable to start Raid.')
        return false
    end

    for _, npcData in pairs(npcs) do
        local mob = xi.raid.spawnNPC(zone, zoneData, npcData.pos, npcData.name, npcData.groupId, npcData.look)
        -- Note: This does change the mob level because ally npcs are of type mob, and
        -- level_restriction is only applied to PCs. However, we need the status to validate that the
        -- npcs are part of the raid.
        -- Because the npcs are not level capped, group ids should be used to define min / max level.
        xi.raid.addLevelCap(mob, zoneData.levelCap)
        table.insert(zoneData.npcs, mob:getID())
    end

    return true
end

-----------------------------------
-- Raid Mob handling.
-----------------------------------

-- Spawns a mob with the given id for the given zone.
xi.raid.spawnMob = function(mobID, zoneData)
    local mob = SpawnMob(mobID)
    if mob == nil then
        return nil
    end

    xi.raid.addLevelCap(mob, zoneData.levelCap)
    mob:setRoamFlags(xi.roamFlag.SCRIPTED)
    table.insert(zoneData.mobs, mobID)

    -- Death listener for tracking win/lose condition
    mob:addListener('DEATH', 'RAID_MOB_DEATH', function(mobArg)
        zoneData.deadMobCount = zoneData.deadMobCount + 1
    end)

    -- A wave is considered complete when all mobs are done despawning
    -- and not just dead. This matters a lot because of spawn timings.
    -- I.e: If mob A dies on wave 1, and another instance of mob A is supposed
    -- to spawn on wave 2, it will not spawn as long as the previous mob is still
    -- despawning
    -- For this reason, we track both death and despawn as separate events
    mob:addListener('DESPAWN', 'RAID_MOB_DESPAWN', function(mobArg)
        zoneData.despawnedMobCount = zoneData.despawnedMobCount + 1
    end)

    return mob
end

-- Given a starting mobID, return the list of randomly selected mob ids. The amount of mobs selected is determined by numMobs.
-- The ids in the given excludedMobs table will not be included in the result.
-- This method assumes that the mob pool is composed by mobIDs that are sequential between firstMobID and lastMobID.
-- e.g: If firstMobId = 1, lastMobID = 4 and numMobs is 2,
-- Then 2 ids randomly selected between { 1, 2, 3, 4 } will be returned without repetitions.
xi.raid.pickMobsFromPool = function(firstMobID, lastMobID, numMobs, excludedMobIDs)
    -- Create dynamic table with valid mobs.
    local unfilteredPool = utils.range(firstMobID, lastMobID)
    local excludedSet    = set(excludedMobIDs)
    local dTableMobPool  = {}
    local dTableMobs     = {}

    for _, v in ipairs(unfilteredPool) do
        if not excludedSet[v] then
            table.insert(dTableMobPool, v)
        end
    end

    -- Validate input.
    if numMobs > #dTableMobPool then
        printf('[warning] pickMobsFromPool called with numMobs > mobIds. Num Mobs: %i. Pool size: %i', numMobs, #dTableMobPool)
        numMobs = #dTableMobPool
    end

    if numMobs <= 0 then
        printf('[error] Invalid numMobs picked. Should be > 0.')
        return {}
    end

    -- Now we can apply a common algorithm used to 'shuffle a deck of cards'
    for i = 1, numMobs do
        -- Pick random index from J to pool end. Add the picked element to result
        local pickedIndex = math.random(i, #dTableMobPool)

        table.insert(dTableMobs, dTableMobPool[pickedIndex])

        -- Now swap the picked element with the first element of the array.
        -- This effectively makes the picked element not elegible for future picks.
        dTableMobPool[pickedIndex], dTableMobPool[i] = dTableMobPool[i], dTableMobPool[pickedIndex]
    end

    return dTableMobs
end

-----------------------------------
-- Raid Reward handling.
-----------------------------------

-- Distributes loot amongst all players
xi.raid.handleLootRolls = function(levelCap, players)
    local lootTable = xi.raid.loot[levelCap]
    local max       = 0

    for _, entry in ipairs(lootTable) do
        max = max + entry.droprate
    end

    local roll = math.random(max)

    for _, entry in pairs(lootTable) do
        max = max - entry.droprate

        if roll > max then
            if entry.itemid ~= 0 then
                for _, player in ipairs(players) do
                    if player ~= nil then
                        player:addTreasure(entry.itemid)

                        return
                    end
                end
            end

            break
        end
    end
end

xi.raid.handleGilPayout = function(levelCap, players)
    -- We have two captures at level 30 being rewarded a total of 3k gil.
    -- This is an assumption of how the rest of tiers work.
    local payout = xi.settings.main.GIL_RATE * levelCap * 100 * #players

    debugLog('Payout: ' .. payout)

    if #players > 0 then
        for _, player in ipairs(players) do
            if player ~= nil then
                local gil = payout / #players

                player:addGil(gil)
                player:messageSpecial(zones[player:getZoneID()].text.GIL_OBTAINED, gil)
            end
        end
    end
end

-----------------------------------
-- Raid Progression handling.
-----------------------------------
-- Randomly assigns aggro between the given groups of entity IDs.
xi.raid.aggroGroups = function(group1, group2)
    for _, entityId1 in pairs(group1) do
        for _, entityId2 in pairs(group2) do
            local entity1 = GetMobByID(entityId1)
            local entity2 = GetMobByID(entityId2)

            if entity1 == nil or entity2 == nil then
                printf('[warning] Could not apply aggro because either %i or %i are not valid entities', entityId1, entityId2)
            else
                debugLogf('Applying enmity: %i <-> %i', entityId1, entityId2)
                entity1:addEnmity(entity2, math.random(1, 5), math.random(1, 5))
                entity2:addEnmity(entity1, math.random(1, 5), math.random(1, 5))
            end
        end
    end
end

-- Main tick that will run the state machine for raid logic
xi.raid.tick = function(npc)
    local zone     = npc:getZone()
    local zoneData = xi.raid.zoneData[zone:getID()]
    local ID       = zones[npc:getZoneID()]

    local entityMapper = function(_, entityId)
        return GetPlayerByID(entityId)
    end

    local players = utils.map(zoneData.players, entityMapper)

    switch (zoneData.state) : caseof
    {
        [xi.raid.state.SPAWN_NPCS] = function()
            debugLog('State: Spawn NPCs')

            if #players > 0 then
                for _, player in ipairs(players) do
                    if player ~= nil then
                        player:changeMusic(0, 223)
                        player:changeMusic(1, 223)
                        player:changeMusic(2, 223)
                        player:changeMusic(3, 223)
                        player:printToPlayer(zoneData.guardShoutStart, xi.msg.channel.NS_SHOUT)
                    end
                end
            end

            zoneData.stateTime = GetSystemTime()

            if xi.raid.spawnNPCs(zone, zoneData) then
                zoneData.state = xi.raid.state.BATTLE
            else
                debugPrintToPlayers(players, 'Unable to spawn NPCs')
                zoneData.state = xi.raid.state.ENDED
            end
        end,

        [xi.raid.state.BATTLE] = function()
            debugLog('State: Battle')

            -- We do not cache player entity state as they can reraise or DC,
            -- making caching more error prone
            local isAliveFn = function(_, player)
                return player ~= nil and player:isAlive()
            end

            local allPlayersDead = not utils.any(players, isAliveFn)

            -- This caching works because the same mob ID is never used to respawn a mob
            -- within the same wave.
            local allMobsDead      = zoneData.deadMobCount == #zoneData.mobs
            local allMobsDespawned = zoneData.despawnedMobCount == #zoneData.mobs

            -- Case 1: Either npcs or players are dead. End event.
            local allNPCsDead = #zoneData.npcs == zoneData.deadNPCCount

            if allNPCsDead or allPlayersDead then
                -- You fought hard, and you proved yourself worthy...
                debugPrintToPlayers(players, 'Mission failed by death')
                messagePlayersPrint(players, 'You fought valiantly but your efforts were in vain...')
                zoneData.state = xi.raid.state.ENDED

                return
            end

            -- Case 2: More mobs to spawn in this wave, and past next spawn time. Spawn Mobs.
            local shouldSpawnMobs = GetSystemTime() >= zoneData.nextSpawnTime
            local numGroups       = #zoneData.spawnSchedule[zoneData.waveIndex]
            local isLastGroup     = zoneData.groupIndex > numGroups

            if shouldSpawnMobs and not isLastGroup then
                zoneData.state = xi.raid.state.SPAWN_MOBS

                return
            end

            -- Case 3: All mobs spawned for last wave. Spawn boss
            local numWaves   = #zoneData.spawnSchedule
            local isLastWave = zoneData.waveIndex == numWaves

            if
                shouldSpawnMobs and
                isLastWave and
                isLastGroup and
                not zoneData.bossSpawned
            then
                zoneData.state = xi.raid.state.SPAWN_BOSS

                return
            end

            -- Case 4: All Mobs despawned and this was last group. Check if we advance to next wave.
            if
                allMobsDespawned and
                isLastGroup and
                not isLastWave
            then
                if #players > 0 then
                    for _, player in ipairs(players) do
                        if player ~= nil then
                            player:printToPlayer(utils.randomEntry(zoneData.guardShoutWave), xi.msg.channel.NS_SHOUT)
                        end
                    end
                end
                zoneData.state = xi.raid.state.ADVANCE_WAVE

                return
            end

            -- Case 5: All mobs are dead and this was last group and last wave. Grant loot.
            if allMobsDead and isLastGroup and isLastWave and zoneData.bossSpawned then
                zoneData.state = xi.raid.state.GRANT_LOOT

                return
            end

            -- Case 6: Timeout
            if GetSystemTime() > zoneData.endTime then
                -- You fought hard, and you proved yourself worthy...
                debugPrintToPlayers(players, 'Mission failed by timeout')
                messagePlayersPrint(players, 'The raiding party successfully escaped with their loot...')

                zoneData.state = xi.raid.state.ENDED
            end
        end,

        [xi.raid.state.SPAWN_BOSS] = function()
            debugLog('State: Spawn Boss')
            debugPrintToPlayers(players, 'Spawning boss')

             if #players > 0 then
                for _, player in ipairs(players) do
                    if player ~= nil then
                        player:changeMusic(0, 226)
                        player:changeMusic(1, 226)
                        player:changeMusic(2, 226)
                        player:changeMusic(3, 226)
                        player:printToPlayer(zoneData.bossData[2], xi.msg.channel.NS_SHOUT)
                    end
                end
            end

            local data = zoneData.bossData[1]

            local mob = zone:insertDynamicEntity({
                objtype = xi.objType.MOB,
                name = data[1],
                x = data[2],
                y = data[3],
                z = data[4],
                rotation = data[5],
                groupId = data[6],
                groupZoneId = data[7],
                releaseIdOnDisappear = true,
                specialSpawnAnimation = false
            })

            if not mob then
                return
            end

            mob:setSpawn(data[2], data[3], data[4], data[5])
            mob:spawn()
            mob:setDropID(0)
            mob:setMobMod(xi.mobMod.NO_DROPS, 1)
            DisallowRespawn(mob:getID(), true)
            mob:setBaseSpeed(25)

            mob:addListener('DEATH', 'RAID_BOSS_DEATH', function(mobArg)
                zoneData.deadMobCount = zoneData.deadMobCount + 1
                if #players > 0 then
                    for _, player in ipairs(players) do
                        if player ~= nil then
                            player:printToPlayer(zoneData.bossData[3], xi.msg.channel.NS_SHOUT)
                        end
                    end
                end
            end)

            mob:addListener('DESPAWN', 'RAID_BOSS_DESPAWN', function(mobArg)
                zoneData.despawnedMobCount = zoneData.despawnedMobCount + 1
                table.remove(zoneData.mobs, mob:getID())
            end)

            xi.raid.addLevelCap(mob, zoneData.levelCap)
            table.insert(zoneData.mobs, mob:getID())

            xi.raid.aggroGroups({ mob:getID() }, zoneData.npcs)

            zoneData.bossSpawned = true
            zoneData.state = xi.raid.state.BATTLE
        end,

        [xi.raid.state.ADVANCE_WAVE] = function()
            debugLog('State: Advance Wave')
            debugLogf('Wave Idx: %i. Waves: %i', zoneData.waveIndex, #zoneData.spawnSchedule)
            debugLogf('Next wave: %i', zoneData.waveIndex)
            debugPrintToPlayers(players, 'Wave ' .. zoneData.waveIndex .. ' cleared')

            zoneData.waveIndex = zoneData.waveIndex + 1
            zoneData.groupIndex = 1
            zoneData.nextSpawnTime = GetSystemTime() + xi.raid.waves.delayBetweenGroups
            zoneData.state = xi.raid.state.BATTLE
            zoneData.mobs = {}

            -- reset mob state cache, but not npc since they dont respawn each wave
            zoneData.deadMobCount      = 0
            zoneData.despawnedMobCount = 0
        end,

        [xi.raid.state.SPAWN_MOBS] = function()
            debugLog('State: Spawn Mobs')

            if zoneData.spawnSchedule[zoneData.waveIndex] == nil then
                printf('[error] No spawn schedule for wave: %d. Num Parties: %d', zoneData.waveIndex, zoneData.numParties)
                zoneData.state = xi.raid.state.ENDED

                return
            end

            local poolSize = utils.sum(zoneData.spawnSchedule[zoneData.waveIndex], function(_, v)
                return v
            end)

            local numMobs   = zoneData.spawnSchedule[zoneData.waveIndex][zoneData.groupIndex]

            if zoneData.mobData == nil then
                printf('[error] No mobData for zone.')
                zoneData.state = xi.raid.state.ENDED

                return
            end

            for i = 1, numMobs do
                npc:timer(i * 2000, function()  -- delay increases by 2 seconds each iteration

                    local isAliveFn = function(_, player)
                        return player ~= nil and player:isAlive()
                    end
                    local allPlayersDead = not utils.any(players, isAliveFn)
                    local allNPCsDead = #zoneData.npcs == zoneData.deadNPCCount
                    if allPlayersDead or allNPCsDead then
                        return
                    end

                    local data = utils.randomEntry(zoneData.mobData)

                    local mob = zone:insertDynamicEntity({
                        objtype = xi.objType.MOB,
                        name = data[1],
                        x = data[2],
                        y = data[3],
                        z = data[4],
                        rotation = data[5],
                        groupId = data[6],
                        groupZoneId = data[7],
                        releaseIdOnDisappear = true,
                        specialSpawnAnimation = false
                    })

                    if not mob then
                        return
                    end

                    mob:setSpawn(data[2], data[3], data[4], data[5])
                    mob:spawn()
                    mob:setDropID(0)
                    mob:setMobMod(xi.mobMod.NO_DROPS, 1)
                    DisallowRespawn(mob:getID(), true)
                    mob:setBaseSpeed(25)

                    mob:addListener('DEATH', 'RAID_MOB_DEATH', function(mobArg)
                        zoneData.deadMobCount = zoneData.deadMobCount + 1
                    end)

                    mob:addListener('DESPAWN', 'RAID_MOB_DESPAWN', function(mobArg)
                        zoneData.despawnedMobCount = zoneData.despawnedMobCount + 1
                        table.remove(zoneData.mobs, mob:getID())
                    end)

                    xi.raid.addLevelCap(mob, zoneData.levelCap)
                    table.insert(zoneData.mobs, mob:getID())

                    xi.raid.aggroGroups({ mob:getID() }, zoneData.npcs)
                end)
            end

            debugPrintToPlayers(players, 'Spawn: ' .. numMobs .. '/' .. poolSize .. '. Wave: ' .. zoneData.waveIndex)

            zoneData.nextSpawnTime = GetSystemTime() + xi.raid.waves.delayBetweenGroups
            zoneData.state = xi.raid.state.BATTLE
            zoneData.groupIndex = zoneData.groupIndex + 1
        end,

        [xi.raid.state.GRANT_LOOT] = function()
            debugLog('State: Grant Loot')
            debugPrintToPlayers(players, 'Mission success')
            messagePlayersPrint(players, 'The enemy raiding party has been defeated!')

            xi.raid.handleLootRolls(zoneData.levelCap, players)
            xi.raid.handleGilPayout(zoneData.levelCap, players)

            zoneData.state = xi.raid.state.ENDED
        end,

        [xi.raid.state.ENDED] = function()
            debugLog('State: Ended')

            xi.raid.stop(zone)
        end,
    }

    -- Updates last tick so watchdog knows we are ok
    zoneData.lastTick = GetSystemTime()

    -- Keep running tick until done
    if zoneData.isRunning then
        npc:timer(1000, function(npcArg)
            xi.raid.tick(npcArg)
        end)
    end
end

-- Gets the spawn schedule for the player starting raid.
xi.raid.getSpawnSchedule = function(player)
    local spawnSchedule = xi.raid.waves.spawnSchedule[1]

    if spawnSchedule == nil then
        -- Leave the log there even if valid most times, because it may help us cause bad use cases
        debugLogf('[warning] Spawn schedule not found for number of parties: %d. Ignore if player has no party.', numParties)
        spawnSchedule = xi.raid.waves.spawnSchedule[1]
    end

    return spawnSchedule
end

-----------------------------------
-- Raid Start and End.
-----------------------------------
-- Watchdock tick that guarantees our main tick is always running. If not, stops garrison and clears the invalid state.
local function raidWatchdog(npc)
    npc:timer(5000, function(npcArg)
        local zoneData     = xi.raid.zoneData[npcArg:getZoneID()]
        local tickInterval = 2

        if
            zoneData.isRunning and
            GetSystemTime() - zoneData.lastTick > tickInterval
        then
            local zone = npcArg:getZone()
            debugLogf('[error] Invalid raid state detected for zone: %s. Stopping it now.', zone:getName())
            xi.raid.stop(zone)
        end

        if zoneData.isRunning then
            raidWatchdog(npcArg)
        end
    end)
end

xi.raid.start = function(player, npc)
    local zone             = player:getZone()
    local zoneData         = xi.raid.zoneData[zone:getID()]
    if zoneData == nil then
        player:printToPlayer('No raid data found for the zone.')
        return
    end
    zoneData.players       = {}
    zoneData.spawnSchedule = xi.raid.getSpawnSchedule(player)
    zoneData.npcs          = {}
    zoneData.mobs          = {}
    zoneData.state         = xi.raid.state.SPAWN_NPCS
    zoneData.isRunning     = true
    zoneData.stateTime     = GetSystemTime()
    zoneData.waveIndex     = 1
    zoneData.groupIndex    = 1
    zoneData.bossSpawned   = false
    -- First mob spawn takes xi.raid.waves.delayBetweenGroups to start
    zoneData.nextSpawnTime     = GetSystemTime() + xi.raid.waves.delayBetweenGroups
    zoneData.endTime           = GetSystemTime() + xi.settings.main.GARRISON_TIME_LIMIT
    zoneData.deadNPCCount      = 0
    zoneData.deadMobCount      = 0
    zoneData.despawnedMobCount = 0
    zoneData.lastTick          = GetSystemTime()

    -- Adds level cap / registers lockout for the player / zone
    for _, member in pairs(zone:getPlayers()) do
        if member:getZoneID() == player:getZoneID() then
            xi.raid.addLevelCap(member, zoneData.levelCap)

            table.insert(zoneData.players, member:getID())
        end
    end

    -- The starting NPC is the 'anchor' for all timers and logic for this Garrison
    -- Kick off the watchdog to guarantee state consistency
    raidWatchdog(npc)
    -- Kick off the main tick that drives garrison logic
    xi.raid.tick(npc)
end

-- Stops and cleans up the current raid event (if any) on the given zone
-- Can be called externally from GM commands
xi.raid.stop = function(zone)
    local zoneData = xi.raid.zoneData[zone:getID()]

    for _, entityId in pairs(zoneData.players or {}) do
        local entity = GetPlayerByID(entityId)

        if entity ~= nil then
            entity:delStatusEffect(xi.effect.LEVEL_RESTRICTION)
        end
    end

    for _, entityId in pairs(zoneData.npcs or {}) do
        DespawnMob(entityId, zone)
    end

    for _, entityId in pairs(zoneData.mobs or {}) do
        DespawnMob(entityId, zone)
    end

    local entityMapper = function(_, entityId)
        return GetPlayerByID(entityId)
    end
    local players = utils.map(zoneData.players, entityMapper)
    if #players > 0 then
        for _, player in ipairs(players) do
            if player ~= nil then
                player:changeMusic(0, zoneData.cityMusic)
                player:changeMusic(1, zoneData.cityMusic)
                player:printToPlayer(zoneData.guardShoutEnd, xi.msg.channel.NS_SHOUT)
            end
        end
    end

    zoneData.players       = {}
    zoneData.spawnSchedule = {}
    zoneData.npcs          = {}
    zoneData.mobs          = {}
    zoneData.isRunning     = false
end

xi.raid.win = function(zone)
    local zoneData = xi.raid.zoneData[zone:getID()]
    zoneData.state = xi.raid.state.GRANT_LOOT
end

-- Raid Progression
xi.raid.state =
{
    SPAWN_NPCS          = 0,
    BATTLE              = 1,
    SPAWN_MOBS          = 2,
    SPAWN_BOSS          = 3,
    ADVANCE_WAVE        = 4,
    GRANT_LOOT          = 5,
    ENDED               = 6,
}

-- Loot is determined by LevelCap
xi.raid.loot =
{
    [20] =
    {
        { itemid = xi.item.DRAGON_CHRONICLES, droprate = 1000 },
        { itemid = xi.item.GARRISON_TUNICA,   droprate =  350 },
        { itemid = xi.item.GARRISON_BOOTS,    droprate =  350 },
        { itemid = xi.item.GARRISON_HOSE,     droprate =  350 },
        { itemid = xi.item.GARRISON_GLOVES,   droprate =  350 },
        { itemid = xi.item.GARRISON_SALLET,   droprate =  350 },
    },
}

xi.raid.waves =
{
    spawnSchedule =
    {
        -- 1 Party
        [1] =
        {
            [1] = { 4, 3, 2 },
            [2] = { 2, 3, 4, 2 },
            [3] = { 3, 6, 5, 2 },
            [4] = { 2, 5, 2, 3 },
        },
    },

    -- How many seconds before each group spawns
    delayBetweenGroups = 15,
}

return m
