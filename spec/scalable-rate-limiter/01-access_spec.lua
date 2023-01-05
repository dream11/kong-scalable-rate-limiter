local helpers        = require "spec.helpers"
local cjson          = require "cjson"

-- REDIS_HOST and REDIS_PORT taken from .pongo/redis-cluster.yml
local REDIS_HOST     = "172.18.55.1"
local REDIS_HOSTNAME = "pongo-test-network"
local REDIS_PORT     = 7101
local REDIS_PASSWORD = ""
local REDIS_DATABASE = 1

local fmt = string.format
local proxy_client = helpers.proxy_client

-- This performs the test up to two times (and no more than two).
-- We are **not** retrying to "give it another shot" in case of a flaky test.
-- The reason why we allow for a single retry in this test suite is because
-- tests are dependent on the value of the current minute. If the minute
-- flips during the test (i.e. going from 03:43:59 to 03:44:00), the result
-- will fail. Since each test takes less than a minute to run, running it
-- a second time right after that failure ensures that another flip will
-- not occur. If the second execution failed as well, this means that there
-- was an actual problem detected by the test.
local function it_with_retry(desc, test)
    return it(desc, function(...)
        if not pcall(test, ...) then
        ngx.sleep(61 - (ngx.now() % 60))  -- Wait for minute to expire
        test(...)
        end
    end)
end


local function GET(url, opts, res_status)
    ngx.sleep(0.010)

    local client = proxy_client()
    local res, err  = client:get(url, opts)
    if not res then
        client:close()
        return nil, err
    end

    local body, err = assert.res_status(res_status, res)
    if not body then
        return nil, err
    end

    client:close()

    return res, body
end

for _, strategy in helpers.each_strategy() do
    for _, policy in ipairs({ "redis", "batch-redis"}) do
        describe(fmt("Plugin: rate-limiting (access) with policy: %s [#%s]", policy, strategy), function()
            local bp
            local db

            local limit_by_header = "rate-limit-header"
            local per_minute_limit = 6
            local headers_1 = {
                [limit_by_header] = "key1",
            }

            local headers_2 = {
                [limit_by_header] = "key2",
            }

            local empty_headers = {}

            local limit_by_service_config = {
                policy         = policy,
                minute         = per_minute_limit,
                redis_host     = REDIS_HOST,
                redis_port     = REDIS_PORT,
                limit_by       = "service",
                batch_size     = 2,
            }
                
            local limit_by_service_config_hostname = {
                policy         = policy,
                minute         = per_minute_limit,
                redis_host     = REDIS_HOSTNAME,
                redis_port     = REDIS_PORT,
                limit_by       = "service",
                batch_size     = 2,
            }

            local limit_by_header_config = {
                policy         = policy,
                minute         = per_minute_limit,
                redis_host     = REDIS_HOST,
                redis_port     = REDIS_PORT,
                limit_by       = "header",
                header_name    = limit_by_header,
                batch_size     = 2,
            }

            describe("global level plugin limit by service", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    -- Global level Rate limiting plugin limit by service
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        config = limit_by_service_config,
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks requests over limit on same service", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    local res = GET("/service_1_route_1", nil, 429)
                end)

                it_with_retry("blocks requests over limit on same service with multiple routes", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_2", nil, 200)
                    end

                    local res = GET("/service_3_route_1", nil, 429)
                    local res = GET("/service_3_route_2", nil, 429)
                end)

                it_with_retry("allows requests upto limit on each different service", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit do
                        local res = GET("/service_2_route_1", nil, 200)
                    end
                end)
            end)
                
            describe("global level plugin limit by service using redis hostname", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    -- Global level Rate limiting plugin limit by service
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        config = limit_by_service_config_hostname,
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks requests over limit on same service", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    local res = GET("/service_1_route_1", nil, 429)
                end)

                it_with_retry("blocks requests over limit on same service with multiple routes", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_2", nil, 200)
                    end

                    local res = GET("/service_3_route_1", nil, 429)
                    local res = GET("/service_3_route_2", nil, 429)
                end)

                it_with_retry("allows requests upto limit on each different service", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit do
                        local res = GET("/service_2_route_1", nil, 200)
                    end
                end)
            end)

            describe("global level plugin limit by header", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    -- Global level Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        config = limit_by_header_config,
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks requests over limit on same header (one route)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_1 }, 429)
                end)

                it_with_retry("blocks requests over limit on same header (for any service, route)", function()
                    for i = 1, per_minute_limit/3 do
                        local res = GET("/service_1_route_1", { headers = headers_2 }, 200)
                    end

                    for i = 1, per_minute_limit/3 do
                        local res = GET("/service_2_route_1", { headers = headers_2 }, 200)
                    end

                    for i = 1, per_minute_limit/3 do
                        local res = GET("/service_3_route_1", { headers = headers_2 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_2 }, 429)
                    local res = GET("/service_2_route_1", { headers = headers_2 }, 429)
                    local res = GET("/service_3_route_1", { headers = headers_2 }, 429)
                    local res = GET("/service_3_route_2", { headers = headers_2 }, 429)
                end)

                it_with_retry("allows requests upto limit on different header (for any service, route)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_3_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_2 }, 200)
                    local res = GET("/service_2_route_1", { headers = headers_2 }, 200)
                    local res = GET("/service_3_route_1", { headers = headers_2 }, 200)
                    local res = GET("/service_3_route_2", { headers = headers_2 }, 200)
                end)

                it_with_retry("does not block request without header identifier", function()
                    for i = 1, (per_minute_limit + 1) do
                        local res = GET("/service_1_route_1", { headers = empty_headers }, 200)
                    end
                end)
            end)

            describe("service level plugin limit by service", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    -- Service-1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        service = service_1,
                        config = limit_by_service_config,
                    }

                    -- Service-2 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        service = service_2,
                        config = limit_by_service_config,
                    }

                    -- Service-3 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        service = service_3,
                        config = limit_by_service_config,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks requests over limit on same service", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    local res = GET("/service_1_route_1", nil, 429)
                end)

                it_with_retry("blocks requests over limit (same service, any route)", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_2", nil, 200)
                    end

                    local res = GET("/service_3_route_1", nil, 429)
                    local res = GET("/service_3_route_2", nil, 429)
                end)

                it_with_retry("allows requests upto limit (different service)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit do
                        local res = GET("/service_2_route_1", nil, 200)
                    end
                end)
            end)

            describe("service level plugin limit by header", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    -- Service-1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        service = service_1,
                        config = limit_by_header_config,
                    }

                    -- Service-2 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        service = service_2,
                        config = limit_by_header_config,
                    }

                    -- Service-3 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        service = service_3,
                        config = limit_by_header_config,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks requests over limit on same header (one route)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_1 }, 429)
                end)

                it_with_retry("blocks requests over limit on same header (same service, any route)", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_1", { headers = headers_1 }, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_2", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_3_route_1", { headers = headers_1 }, 429)
                    local res = GET("/service_3_route_2", { headers = headers_1 }, 429)
                end)

                it_with_retry("allows requests upto limit on different header (for any service or route)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_2 }, 200)
                    local res = GET("/service_2_route_1", { headers = headers_2 }, 200)
                    local res = GET("/service_3_route_1", { headers = headers_2 }, 200)
                    local res = GET("/service_3_route_2", { headers = headers_2 }, 200)
                end)

                it_with_retry("allows requests upto limit on same header (different service)", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_2_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    local res = GET("/service_2_route_1", { headers = headers_1 }, 200)
                end)

                it_with_retry("does not block request without header identifier", function()
                    for i = 1, (per_minute_limit + 1) do
                        local res = GET("/service_1_route_1", { headers = empty_headers }, 200)
                    end
                end)
            end)

            describe("route level plugin limit by header", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    local service_1_route_1 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    local service_2_route_1 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    local service_3_route_1 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    local service_3_route_2 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    -- service_1_route_1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_1_route_1,
                        config = limit_by_header_config,
                    }

                    -- service_2_route_1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_2_route_1,
                        config = limit_by_header_config,
                    }

                    -- service_3_route_1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_3_route_1,
                        config = limit_by_header_config,
                    }

                    -- service_3_route_2 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_3_route_2,
                        config = limit_by_header_config,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks 7th request on same header (one route)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_1 }, 429)
                end)

                it_with_retry("allows 7th request on same header different service different route", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_2_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_1_route_1", { headers = headers_1 }, 200)
                    local res = GET("/service_2_route_1", { headers = headers_1 }, 200)
                end)

                it_with_retry("allows 7th request on same header same service different route", function()
                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_1", { headers = headers_1 }, 200)
                    end

                    for i = 1, per_minute_limit/2 do
                        local res = GET("/service_3_route_2", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_3_route_1", { headers = headers_1 }, 200)
                    local res = GET("/service_3_route_2", { headers = headers_1 }, 200)
                end)

                it_with_retry("allows 7th request on different header same route", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_3_route_1", { headers = headers_1 }, 200)
                    end

                    local res = GET("/service_3_route_1", { headers = headers_2 }, 200)
                end)

                it_with_retry("does not block request without header identifier", function()
                    for i = 1, (per_minute_limit + 1) do
                        local res = GET("/service_1_route_1", { headers = empty_headers }, 200)
                    end
                end)
            end)

            describe("route level plugin limit by service", function()
                lazy_setup(function()
                    helpers.kill_all()

                    bp, db = helpers.get_db_utils(strategy, nil, {"scalable-rate-limiter"})

                    -- Add request termination plugin at global level to return 200 response for all api calls
                    bp.plugins:insert {
                        name = "request-termination",
                        config = {
                            status_code = 200,
                        },
                    }

                    local service_1 = bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_1",
                    }

                    local service_2 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_2",
                    }

                    local service_3 =  bp.services:insert {
                        protocol = "http",
                        host = mock_host,
                        port = mock_port,
                        name = "service_3",
                    }

                    local service_1_route_1 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_1_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_1,
                    }

                    local service_2_route_1 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_2_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_2,
                    }

                    local service_3_route_1 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_1"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    local service_3_route_2 = bp.routes:insert {
                        methods = {"GET"},
                        protocols = {"http"},
                        paths = {"/service_3_route_2"},
                        strip_path = false,
                        preserve_host = true,
                        service = service_3,
                    }

                    -- service_1_route_1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_1_route_1,
                        config = limit_by_service_config,
                    }

                    -- service_2_route_1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_2_route_1,
                        config = limit_by_service_config,
                    }

                    -- service_3_route_1 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_3_route_1,
                        config = limit_by_service_config,
                    }

                    -- service_3_route_2 Rate limiting plugin limit by header
                    bp.plugins:insert {
                        name = "scalable-rate-limiter",
                        route = service_3_route_2,
                        config = limit_by_service_config,
                    }

                    assert(helpers.start_kong({
                        database   = strategy,
                        nginx_conf = "spec/fixtures/custom_nginx.template",
                        plugins = "bundled,scalable-rate-limiter",
                    }))
                end)

                lazy_teardown(function()
                    helpers.stop_kong()
                    assert(db:truncate())
                end)

                it_with_retry("blocks requests over limit (one route)", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    local res = GET("/service_1_route_1", nil, 429)
                end)

                it_with_retry("allows requests under limit different service different route", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_1_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit do
                        local res = GET("/service_2_route_1", nil, 200)
                    end
                end)

                it_with_retry("allows requests under limit same service different route", function()
                    for i = 1, per_minute_limit do
                        local res = GET("/service_3_route_1", nil, 200)
                    end

                    for i = 1, per_minute_limit do
                        local res = GET("/service_3_route_2", nil, 200)
                    end
                end)
            end)
        end)
    end
end
