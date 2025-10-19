-----------------------------------
-- func: raid <command> (player)
-- commands:
-- !raid start (player) starts a raid event for the given player (or targetted one). This bypasses requirements like lockout
-- !raid stop  (player) stops the raid (if any) currently running in the player's zone
-- !raid win (player) win the raid (if any) currently running in the player's zone
-----------------------------------
---@type TCommand
local commandObj = {}

commandObj.cmdprops =
{
    permission = 1,
    parameters = 'ss'
}

local function error(player, msg)
    local usage = 'Usage: !raid <command> (player)'
    player:printToPlayer(msg .. '\n' .. usage)
end

commandObj.onTrigger = function(player, command, target)
    -- Validate command
    if command == nil then
        error(player, 'Invalid command')
        return
    end

    -- Obtain target
    local targ = player:getCursorTarget()
    if target ~= nil then
        targ = GetPlayerByName(target)

        if targ == nil then
            error(player, string.format('Player named "%s" not found', target))
            return
        end
    else -- targ == nil, select player
        targ = player
    end

    -- Validate target
    if targ == nil and target == nil then
        error(player, 'Either provide a valid target name (in same zone) or target the desired player')
        return
    end

    local zone = targ:getZone()
    if not zone then
        return
    end

    switch(command): caseof
    {
        ['start'] = function()            
            targ:printToPlayer(string.format('%s raid started', zone:getName()))
            xi.raid.start(targ, targ)
        end,

        ['stop'] = function()
            xi.raid.stop(targ:getZone())
            targ:printToPlayer(string.format('%s raid stopped', zone:getName()))
        end,

        ['win'] = function()
            xi.raid.win(targ:getZone())
        end,
    }
end

return commandObj
