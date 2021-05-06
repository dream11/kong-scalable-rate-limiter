local redis_cluster = require "resty.rediscluster"
local resty_lock = require "resty.lock"
local worker = ngx.worker
local kong = kong
local _M = {}

local data = {
    conn_pool = nil
}

local function prepare_config(conf)
    return {
        name = "d11-redis-cluster",
        serv_list = {
            { ip = conf.redis_host, port = conf.redis_port or 6379 }
        },
        keepalive_timeout = conf.redis_keepalive_timeout or 60000,
        keepalive_cons = conf.redis_pool_size or 5,
        connect_timeout = conf.redis_connect_timeout or 10000,
        send_timeout = conf.redis_send_timeout or 10000,
        read_timeout = conf.redis_read_timeout or 10000,
        max_redirection = conf.redis_max_redirection or 2,
        max_connection_attempts = conf.redis_max_connection_attempts or 2,
        dict_name = "kong_db_cache",
        connect_opts = {
            pool_size = conf.redis_pool_size or 5,
            backlog = conf.redis_backlog or 0
        }
    }
end

function _M.get_redis_conn_pool(conf)
     -- step 1:
    if data.conn_pool then
        return data.conn_pool
    else
        kong.log.debug("Redis pool not present, will initialize")
    end

    -- local cache miss!
    -- step 2:
    local lock, err = resty_lock:new("kong_db_cache", { exptime = 5, timeout = 0 })
    if not lock then
        kong.log.debug(err)
        return false, "Unable to create lock object for redis connection"
    end

    local wid = worker.id()
    local key = "d11-redis-cluster_lock_" .. wid
    kong.log.debug("Acquiring lock for redis connection: " .. key)
    local elapsed, err = lock:lock(key)
    if not elapsed then
        kong.log.err(err)
        return nil, "failed to acquire the lock for redis connection: " .. key
    end

    -- step 3:
    -- someone might have already put the value into the local cache
    -- so we check it here again:
    if data.conn_pool then
        local ok, err = lock:unlock()
        if not ok then
            kong.log.err("failed to unlock: ", err)
        end
        kong.log.debug("Redis pool present after lock was acquired")
        return data.conn_pool
    end

    local config = prepare_config(conf)
    local red, err_redis = redis_cluster:new(config)

    -- Unlock before exiting
    kong.log.debug("Releasing lock for redis connection: " .. key)
    local ok, err = lock:unlock()
    if not ok then
        kong.log.err("failed to unlock key: " .. key, err)
    end

	if err_redis then
		kong.log.err("failed to connect to Redis: ", err)
		return nil, err_redis
	end

    kong.log.debug("Redis connection pool initialized")
    data.conn_pool = red
	return data.conn_pool
end

return _M