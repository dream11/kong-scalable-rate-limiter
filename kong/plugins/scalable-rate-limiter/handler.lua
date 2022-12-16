local policies = require "kong.plugins.scalable-rate-limiter.policies"
local EXPIRATION = require "kong.plugins.scalable-rate-limiter.expiration"
local timestamp = require "kong.tools.timestamp"

local kong = kong
local ngx = ngx
local time = ngx.time
local pairs = pairs
local tostring = tostring
local timer_at = ngx.timer.at
local max = math.max
local floor = math.floor
local cjson = require "cjson"

local EMPTY = {}

local RATELIMIT_LIMIT     = "RateLimit-Limit"
local RATELIMIT_REMAINING = "RateLimit-Remaining"
local RATELIMIT_RESET     = "RateLimit-Reset"
local RETRY_AFTER         = "Retry-After"


local X_RATELIMIT_LIMIT = {
  second = "X-RateLimit-Limit-Second",
  minute = "X-RateLimit-Limit-Minute",
  hour   = "X-RateLimit-Limit-Hour",
  day    = "X-RateLimit-Limit-Day",
  month  = "X-RateLimit-Limit-Month",
  year   = "X-RateLimit-Limit-Year",
}

local X_RATELIMIT_REMAINING = {
  second = "X-RateLimit-Remaining-Second",
  minute = "X-RateLimit-Remaining-Minute",
  hour   = "X-RateLimit-Remaining-Hour",
  day    = "X-RateLimit-Remaining-Day",
  month  = "X-RateLimit-Remaining-Month",
  year   = "X-RateLimit-Remaining-Year",
}

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
    elseif conf.limit_by == "consumer" then
        identifier = kong.request.get_header("X-Consumer-Username")
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

local function populate_client_headers(conf, limits_per_consumer)
    local status = true
    if not conf.hide_client_headers then
        if conf.limit_by == "consumer" and limits_per_consumer == nil then
            status = false
        end
    end
    return status
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

    local limits_per_consumer
    if conf.limit_by == "consumer" then
        limits_per_consumer = cjson.decode(conf.limit_by_consumer_config)[kong.request.get_header("X-Consumer-Username")]
        if limits_per_consumer ~= nil then
            limits = limits_per_consumer
        end
    end

    local usage, stop, err = get_usage(conf, identifier, current_timestamp, limits)

    if err then
        kong.log.err("failed to get usage: ", tostring(err))
    end
    
    if usage then
        -- Adding headers
        local reset
        local headers
        if populate_client_headers then
          headers = {}
          local timestamps
          local limit
          local window
          local remaining
          for k, v in pairs(usage) do
            local current_limit = v.limit
            local current_window = EXPIRATION[k]
            local current_remaining = v.remaining
            if stop == nil or stop == k then
              current_remaining = current_remaining - 1
            end
            current_remaining = max(0, current_remaining)
    
            if not limit or (current_remaining < remaining)
                         or (current_remaining == remaining and
                             current_window > window)
            then
              limit = current_limit
              window = current_window
              remaining = current_remaining
    
              if not timestamps then
                timestamps = timestamp.get_timestamps(current_timestamp)
              end
    
              reset = max(1, window - floor((current_timestamp - timestamps[k]) / 1000))
            end
    
            headers[X_RATELIMIT_LIMIT[k]] = current_limit
            headers[X_RATELIMIT_REMAINING[k]] = current_remaining
          end
    
          headers[RATELIMIT_LIMIT] = limit
          headers[RATELIMIT_REMAINING] = remaining
          headers[RATELIMIT_RESET] = reset
        end

        -- If get_usage succeeded and limit has been crossed
        if usage and stop then
            headers = headers or {}
            kong.log.err("API rate limit exceeded")
            headers[RETRY_AFTER] = reset
            return kong.response.exit(429, { error = { message = conf.error_message }}, headers)
        end

        if headers then
            kong.response.set_headers(headers)
        end
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
