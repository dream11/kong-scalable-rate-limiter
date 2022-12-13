-- local AppConfig = require "kong.plugins.app-config.config"
local redis_cluster = require "resty.rediscluster"
local resty_lock = require "resty.lock"
local worker = ngx.worker
local inspect = require "inspect"
local _M = {}

local data = {
    conn_pool = nil
}

local function get_redis_config(source_config)
    return {
        name = "d11-redis-cluster",
        serv_list = {
            { ip = source_config.redis_host, port = source_config.redis_port}
        },
        keepalive_timeout = source_config.redis_keepalive_timeout,
        keepalive_cons = source_config.redis_pool_size,
        connect_timeout = source_config.redis_connect_timeout,
        send_timeout = source_config.redis_send_timeout,
        read_timeout = source_config.redis_read_timeout,
        max_redirection = source_config.redis_max_redirection,
        max_connection_attempts = source_config.redis_max_connection_attempts,
        dict_name = "kong_db_cache",
        connect_opts = {
            pool_size = source_config.redis_pool_size,
            backlog = source_config.redis_backlog
        },
        auth = source_config.redis_password
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

    -- step 4:
    local source_config = conf

    -- local err
    -- if conf.use_app_config then
    --     source_config = AppConfig.get_config()
    --     if err then
    --         kong.log.err("Unable to load App config for redis connection" .. err)
    --         return nil, "Unable to load App config"
    --     end
    -- end

    local redis_config = get_redis_config(source_config)
    local red, err_redis = redis_cluster:new(redis_config)

    kong.log.info("******Redis config********")
    kong.log.info(inspect(redis_config))

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
