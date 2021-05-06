local timestamp = require "kong.tools.timestamp"
local connection = require "kong.plugins.advanced-rate-limiting.policies.connection"

local kong = kong
local pairs = pairs
local null = ngx.null
local shm = ngx.shared.kong_rate_limiting_counters
local fmt = string.format


local EMPTY_UUID = "00000000-0000-0000-0000-000000000000"

local function get_service_and_route_ids(conf)
	conf = conf or {}

	local service_id = conf.service_id
	local route_id = conf.route_id

	if not service_id or service_id == null then
		service_id = EMPTY_UUID
	end

	if not route_id or route_id == null then
		route_id = EMPTY_UUID
	end

	return service_id, route_id
end

local get_local_key = function(conf, identifier, period, period_date)
	local service_id, route_id = get_service_and_route_ids(conf)
	return fmt("ratelimit:%s:%s:%s:%s:%s", route_id, service_id, identifier, period_date, period)
end

local EXPIRATION = require "kong.plugins.advanced-rate-limiting.expiration"

return {
	["redis"] = {
		increment = function(conf, limits, identifier, current_timestamp, value)
			local red, err = connection.get_redis_conn_pool(conf)
			if not red then
				return nil, err
			end

			local periods = timestamp.get_timestamps(current_timestamp)

			for period, period_date in pairs(periods) do
				if limits[period] then
					local cache_key = get_local_key(conf, identifier, period, period_date)

					local redis_hit_count = red:incrby(cache_key, value)

					if redis_hit_count == 1 then
						red:expire(cache_key, EXPIRATION[period])
					end
				end
			end

			return true
		end,
		usage = function(conf, identifier, period, current_timestamp)
			local red, err = connection.get_redis_conn_pool(conf)
			if not red then
				return nil, err
			end

			local periods = timestamp.get_timestamps(current_timestamp)
			local cache_key = get_local_key(conf, identifier, period, periods[period])

			local current_metric, err_get = red:get(cache_key)
			if err_get then
				return nil, err_get
			end

			if current_metric == null then
				current_metric = nil
			end

			return current_metric or 0
		end,
	},
	["batch-redis"] = {
		increment = function(conf, limits, identifier, current_timestamp, value)

			local periods = timestamp.get_timestamps(current_timestamp)

			for period, period_date in pairs(periods) do
				-- If a limit has been defined for current period
				if limits[period] then
					local cache_key = get_local_key(conf, identifier, period, period_date)
					local node_hit_count, err = shm:incr(cache_key, value, 0, EXPIRATION[period])

					if not node_hit_count then
						kong.log.err("Could not increment counter for period '", period, "' ", err)
						return nil, err
					end

					-- Update Redis if batch completed
					if node_hit_count % conf.batch_size == 0 then
                        -- If the batch size is too low, then key may not expire due to race conditions
						-- Refer https://redis.io/commands/incr#pattern-rate-limiter-2
                        local red, err_get_redis_connection = connection.get_redis_conn_pool(conf)
                        if not red then
                            return nil, err_get_redis_connection
                        end

                        local redis_hit_count = red:incrby(cache_key, conf.batch_size)
						if redis_hit_count == conf.batch_size then
							red:expire(cache_key, EXPIRATION[period])
						end

                        -- Due to non-atomic get-set, count has some error
						local latest_node_hit_count, err_shm_get = shm:get(cache_key)
                        local set_value
                        if err_shm_get or not latest_node_hit_count then
                            set_value = redis_hit_count
                        else
                            set_value = redis_hit_count + latest_node_hit_count - node_hit_count
                        end

                        local success, err_shm_set = shm:set(cache_key, set_value, EXPIRATION[period])
                        if not success then
                            kong.log.err("Could not set rate-limiting counter in SHM for period '", period, "': ",
                            err_shm_set)
                            return nil, err_shm_set
                        end

					end
				end
			end

			return true
		end,
		usage = function(conf, identifier, period, current_timestamp)
			local periods = timestamp.get_timestamps(current_timestamp)
			local cache_key = get_local_key(conf, identifier, period, periods[period])

			-- Read current_metric from node cache
			local current_metric, err = shm:get(cache_key, nil, function () return 0 end)

			if err then
				return nil, err
			end
			return current_metric
		end,
	},
}
