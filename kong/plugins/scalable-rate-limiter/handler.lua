local policies = require "kong.plugins.scalable-rate-limiter.policies"

local kong = kong
local ngx = ngx
local time = ngx.time
local pairs = pairs
local tostring = tostring
local timer_at = ngx.timer.at

local EMPTY = {}

local RateLimitingHandler = {}

RateLimitingHandler.VERSION = "2.2.0"
RateLimitingHandler.PRIORITY = tonumber(os.getenv("PRIORITY_SCALABLE_RATE_LIMITER")) or 960
kong.log.info("Plugin priority set to " .. RateLimitingHandler.PRIORITY .. (os.getenv("PRIORITY_SCALABLE_RATE_LIMITER") and " from env" or " by default"))

local function get_identifier(conf)
    local identifier

    if conf.limit_by == "service" then
        identifier = (kong.router.get_service() or EMPTY).id
    elseif conf.limit_by == "header" then
        identifier = kong.request.get_header(conf.header_name)
    end

    if not identifier then
        return nil, "No rate-limiting identifier found in request"
    end

    return identifier or kong.client.get_forwarded_ip()
end

local function get_usage(conf, identifier, current_timestamp, limits)
    local usage = {}
    local stop

    for period, limit in pairs(limits) do
        local current_usage, err = policies[conf.policy].usage(conf, identifier, period, current_timestamp)
        if err then
            return nil, nil, err
        end

        current_usage = current_usage or 0

        -- What is the current usage for the configured limit name?
        local remaining = limit - current_usage

        -- Recording usage
        usage[period] = {
            limit = limit,
            remaining = remaining
        }

        if remaining <= 0 then
            stop = period
        end
    end

    return usage, stop
end

local function increment(premature, conf, ...)
    if premature then
        return
    end
    policies[conf.policy].increment(conf, ...)
end

function RateLimitingHandler:access(conf)
    local current_timestamp = time() * 1000

    -- Consumer is identified by ip address or authenticated_credential id
    local identifier, err = get_identifier(conf)

    if err then
        kong.log.err(err)
        return
    end

    -- Load current metric for configured period
    local limits = {
        second = conf.second,
        minute = conf.minute,
        hour = conf.hour,
        day = conf.day
    }

    local usage, stop, err = get_usage(conf, identifier, current_timestamp, limits)
    if err then
        kong.log.err("failed to get usage: ", tostring(err))
    end

    -- If get_usage succeeded and limit has been crossed
    if usage and stop then
        kong.log.err("API rate limit exceeded")
        return kong.response.exit(429, { error = { message = conf.error_message }})
    end

    kong.ctx.plugin.timer = function()
        local ok, err = timer_at(0, increment, conf, limits, identifier, current_timestamp, 1)
        if not ok then
            kong.log.err("failed to create timer: ", err)
        end
    end
end

function RateLimitingHandler:log(_)
    if kong.ctx.plugin.timer then
        kong.ctx.plugin.timer()
    end
end

return RateLimitingHandler
