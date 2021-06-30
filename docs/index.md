[![Continuous Integration](https://github.com/dream11/kong-scalable-rate-limiter/actions/workflows/ci.yml/badge.svg)](https://github.com/dream11/kong-scalable-rate-limiter/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green.svg)

# Scalable Rate Limiter

## Overview

Scalable-rate-limiter is a plugin for [Kong](https://github.com/Mashape/kong) built on top of [Rate-limiting](https://docs.konghq.com/hub/kong-inc/rate-limiting/) plugin. It adds batch updates of rate-limiting counters and also adds support for clustered redis.

## Issues in the bundled Rate Limiting plugin

The `Rate Limiting` plugin bundled with `Kong` works fine upto a certain throughput, after which cassandra and redis policy become hard to scale. This is mainly due to the following problems:

**Problem 1**: At high throughputs, updating the rate-limiting counters on each request can increase the load on the database causing [Hot-Key](https://partners-intl.aliyun.com/help/doc-detail/67252.htm) problem.  
**Solution**: We created a new policy batch-redis which maintains a counter in local memory and updates the rate-limiting counters in DB in a batch. Hot keys are not an issue anymore as the number of requests to Redis go down by a factor of batch size.

**Problem 2**: When rate-limiting counters data grows, we cannot shard them with a redis-cluster since the plugin did not have support for redis-cluster.  
**Solution**: The [lua-resty-redis](https://github.com/openresty/lua-resty-redis) client does not support clustered-redis so we replaced it with [resty-redis-cluster](https://github.com/steve0511/resty-redis-cluster). We faced some issues during stress tests when one of the Redis shard in a cluster went down. To make it more fault tolerant, we made some tweaks to [resty-redis-cluster](https://github.com/steve0511/resty-redis-cluster) library and added the modified version to our plugin's code.

## Changes made

Major changes made to the plugin code:  

1. Added batch-redis policy
2. Added support for redis cluster
3. Made plugin fault tolerant by default i.e. requests will continue to be served if there is some problem with code or redis
4. Removed local, cluster (cassandra/postgres) policies

## How does it work?

The plugin uses fixed time windows to maintain rate-limiting counters (similar to the bundled Rate Limiting plugin)

### redis policy

The rate limiting counters are updated on each request. Recommended for low throughput API's.

### batch-redis policy

Instead of updating the global counter in redis after each request, the request counts are maintained at a (local) node level in the shared cache (amongst nginx workers) which is synchronized with the (global) redis counter whenever a batch is complete.
Consider this scenario:

    batch-size = 500, and throughput = 1 million RPM

Each nginx worker updates the local shared cache after serving a request. Once the local_counter % 500 == 0 , the global redis counter is incremented (by batch size). This global count which is a representative of total number of requests is then used to update the local cache as well. And this process is repeated until the API limit is reached or the time period expires.  
Batching reduces the effective writes made on global redis counter by a factor of `batch_size`. It therefore makes the rate limiting scalable and faster as network calls are avoided on each request.

## Installation

If you're using `luarocks` execute the following:

    luarocks install scalable-rate-limiter

You will also need to enable this plugin by adding it to the list of enabled plugins using `KONG_PLUGINS` environment variable or the `plugins` key in `kong.conf`

    export KONG_PLUGINS=scalable-rate-limiter

OR

    plugins=scalable-rate-limiter

### Parameters

| Parameter | Type | Default  | Required | description |
| --- | --- | --- | --- | --- |
| second | integer |  | false | Maximum number of requests allowed in 1 second |
| minute | integer | | false | Maximum number of requests allowed in 1 minute |
| hour | integer | | false | Maximum number of requests allowed in 1 hour |
| day | integer | | false | Maximum number of requests allowed in 1 day |
| limit_by | string | service | true | Property to limit the requests on (service / header) |
| header_name | string | | true (limit_by: header) | The header name by which to limit the requests if limit_by is selected as header |
| policy | string | redis | true | Update redis at each request (redis) or in batches (batch-redis)  |
| batch_size | integer | 10 | true (when policy: batch-redis) | Redis counters will be updated in batches of this size  |
| redis_host | string |  | true | Redis host |
| redis_port | integer | 6379 | true | Redis port |
| redis_password | string | | false | Redis password |
| redis_connect_timeout(ms) | integer | 200 | true | Redis connect timeout |
| redis_send_timeout(ms) | integer | 100 | true | Redis send timeout |
| redis_read_timeout(ms) | integer | 100 | true | Redis read timeout |
| redis_max_connection_attempts | integer | 2 | true | Total attempts to connect to a Redis node |
| redis_keepalive_timeout(ms) | integer | 60000 | true | Keepalive timeout for Redis connections |
| redis_max_redirection | integer | 2 | true | Number of times a keys is tried when MOVED or ASK response is received from redis server |
| redis_pool_size | integer | 4 | true | Pool size of redis connection pool |
| redis_backlog | integer | 1 | true | Size of redis connection pool backlog  queue|
| error_message | string | API rate limit exceeded | true | Error message sent when rate limit is exhausted |

## Caveats

1. Batching introduces an error of upto `batch_size * (number of kong instances)` since the local count is used to check if request should be allowed or not and it can be outdated (in the worst case) by `batch_size * (number of kong instances)` giving the above error margin.  
This can be mitigated by reducing the batch size to the smallest possible value (which the database can support). In our tests we found this error margin to be too minuscule (<0.5%). This error margin can also be accounted for while deciding the rate limit (if rate limit is 100, set it to 99 accounting for upto 1% error).
2. This plugin only works with a [redis cluster](https://redis.io/topics/cluster-tutorial).

## Roadmap

1. Add support for sliding windows.
2. Add support for custom window size (eg. 2hrs, 3hrs, 10 minutes, 3 days)
