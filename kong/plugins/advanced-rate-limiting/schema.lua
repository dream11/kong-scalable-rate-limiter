local typedefs = require "kong.db.schema.typedefs"
local ORDERED_PERIODS = {"second", "minute", "hour", "day"}
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
return {
	name = "rate-limiting",
	fields = {
		{protocols = typedefs.protocols_http},
		{
			config = {
				type = "record",
				fields = {
					{ second = {type = "number", gt = 0}},
					{ minute = {type = "number", gt = 0}},
					{ hour = {type = "number", gt = 0}},
					{ day = {type = "number", gt = 0}},
					{
						limit_by = {
							type = "string",
							default = "service",
                            one_of = { "consumer", "credential", "ip", "service", "header", "path" },
						}
					},
					{ header_name = typedefs.header_name},
					{
						policy = {
							type = "string",
							default = "redis",
							len_min = 0,
							one_of = {"redis", "batch-redis"}
						}
					},
					{ batch_size = {type = "integer", gt = 1, default = 10}},
                    { redis_host = typedefs.host },
                    { redis_port = typedefs.port({ default = 6379 }), },
                    { redis_password = { type = "string", len_min = 0 }, },
                    { redis_connect_timeout = { type = "number", default = 2000, }, },
                    { redis_send_timeout = { type = "number", default = 2000, }, },
                    { redis_read_timeout = { type = "number", default = 2000, }, },
                    { redis_max_connection_attempts = { type = "number", default = 2, }, },
                    { redis_keepalive_timeout = { type = "number", default = 300000, }, },
                    { redis_max_redirection = { type = "number", default = 2, }, },
                    { redis_pool_size = { type = "number", default = 4, }, },
                    { redis_backlog = { type = "number", default = 0, }, },
					{ error_message = {type = "string", default = "API rate limit exceeded", len_min = 0}}
				},
				custom_validator = validate_periods_order
			}
		}
	},
	entity_checks = {
		{at_least_one_of = {"config.second", "config.minute", "config.hour", "config.day"}},
		{
			conditional = {
				if_field = "config.limit_by",
				if_match = {eq = "header"},
				then_field = "config.header_name",
				then_match = {required = true}
			}
		},
        {
			conditional = {
				if_field = "config.policy",
				if_match = {eq = "redis"},
				then_field = "config.redis_host",
				then_match = {required = true}
			}
		},
	}
}
