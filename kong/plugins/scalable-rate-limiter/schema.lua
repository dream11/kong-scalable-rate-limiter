local typedefs = require "kong.db.schema.typedefs"
local ORDERED_PERIODS = { "second", "minute", "hour", "day" }
local cjson = require "cjson"

local function validate_periods_order(config)
    for i, lower_period in ipairs(ORDERED_PERIODS) do
        local v1 = config[lower_period]
        if type(v1) == "number" then
            for j = i + 1, #ORDERED_PERIODS do
                local upper_period = ORDERED_PERIODS[j]
                local v2 = config[upper_period]
                if type(v2) == "number" and v2 < v1 then
                    return nil, string.format(
                        "The limit for %s(%.1f) cannot be lower than the limit for %s(%.1f)",
                        upper_period,
                        v2,
                        lower_period,
                        v1
                    )
                end
            end
        end
    end

    return true
end

local function validate_limits_per_consumer_config(config)
    return pcall(cjson.decode, config)
end

return {
    name = "scalable-rate-limiter",
    fields = {
        { protocols = typedefs.protocols_http },
        {
            config = {
                type = "record",
                fields = {
                    {
                        second = {
                            type = "number",
                            gt = 0,
                        },
                    },
                    {
                        minute = {
                            type = "number",
                            gt = 0,
                        },
                    },
                    {
                        hour = {
                            type = "number",
                            gt = 0,
                        },
                    },
                    {
                        day = {
                            type = "number",
                            gt = 0,
                        },
                    },
                    {
                        limit_by = {
                            type = "string",
                            default = "service",
                            one_of = { "service", "header", "consumer" },
                        },
                    },
                    {
                        header_name = typedefs.header_name,
                    },
                    {
                        policy = {
                            type = "string",
                            default = "redis",
                            len_min = 0,
                            one_of = {
                                "redis",
                                "batch-redis",
                            },
                        },
                    },
                    {
                        batch_size = {
                            type = "integer",
                            gt = 1,
                            default = 10,
                        },
                    },
                    {
                        error_message = {
                            type = "string",
                            default = "API rate limit exceeded",
                            len_min = 0,
                        },
                    },
                    {
                        redis_host = typedefs.host {
                            required = true
                        },
                    },
                    {
                        redis_password = {
                            type = "string",
                            required = false
                        },
                    },
                    {
                        redis_port = typedefs.port {
                            default = 6379,
                        },
                    },
                    {
                        redis_connect_timeout = typedefs.timeout {
                            default = 200,
                        },
                    },
                    {
                        redis_send_timeout = typedefs.timeout {
                            default = 100,
                        },
                    },
                    {
                        redis_read_timeout = typedefs.timeout {
                            default = 100,
                        },
                    },
                    {
                        redis_keepalive_timeout = typedefs.timeout {
                            default = 60000,
                        },
                    },
                    {
                        redis_max_connection_attempts = {
                            type = "integer",
                            gt = 0,
                            default = 2,
                        },
                    },
                    {
                        redis_max_redirection = {
                            type = "integer",
                            gt = 0,
                            default = 2,
                        },
                    },
                    {
                        redis_pool_size = {
                            type = "integer",
                            gt = 0,
                            default = 4,
                        },
                    },
                    {
                        redis_backlog = {
                            type = "integer",
                            default = 1,
                        },
                    },
                    {
                        hide_client_headers = {
                            type = "boolean",
                            required = true,
                            default = false,
                        },
                    },
                    {
                        limit_by_consumer_config = {
                            type = "string",
                            required = false,
                            custom_validator = validate_limits_per_consumer_config
                        }
                    },
                },
                custom_validator = validate_periods_order,
            },
        },
    },
    entity_checks = {
        { conditional_at_least_one_of = {
            if_field = "config.limit_by",
            if_match = { one_of = { "service", "header" } },
            then_at_least_one_of = {
                "config.second",
                "config.minute",
                "config.hour",
                "config.day",
            },
            then_err = "must set one of %s when 'limit_by' is 'service' or 'header'",
        } },
        {
            conditional = {
                if_field = "config.policy",
                if_match = { eq = "batch-redis" },
                then_field = "config.batch_size",
                then_match = { required = true },
            },
        },
        {
            conditional = {
                if_field = "config.limit_by",
                if_match = { one_of = { "consumer", "header" } },
                then_field = "config.header_name",
                then_match = { required = true },
            },
        },
        {
            conditional = {
                if_field = "config.limit_by",
                if_match = { eq = "consumer" },
                then_field = "config.limit_by_consumer_config",
                then_match = { required = true },
            },
        },
    },
}
