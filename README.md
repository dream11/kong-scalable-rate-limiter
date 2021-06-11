## What is advanced-rate-limiting plugin

**Advanced-rate-limiting** is a plugin for [Kong](https://github.com/Mashape/kong) built on top of [Rate-limiting](https://docs.konghq.com/hub/kong-inc/rate-limiting/) plugin

Following changes are made to the [Rate-limiting](https://docs.konghq.com/hub/kong-inc/rate-limiting/) plugin to improve the performance:
1. Add support for Redis cluster using [Resty-Redis-Cluster](https://github.com/steve0511/resty-redis-cluster) client.
2. Add `batch-redis` policy.

## How does it work

The `Rate Limiting` plugin bundled with `Kong` seems to work fine upto a certain RPM, after which even the cassandra and redis policy are unable to scale. One of the main reasons for this is the Hotkey issue, hits to cache are too concentrated (on 1 key).  
To address this problem, we have tweaked the existing code and introduced a new policy - `batch-redis`.
Also, since the [lua-rest-redis](https://github.com/openresty/lua-resty-redis) client does not support redis cluster we replaced it with [Resty-Redis-Cluster](https://github.com/steve0511/resty-redis-cluster). We have also made a change to [Resty-Redis-Cluster](https://github.com/steve0511/resty-redis-cluster) to make it fault taulerant.

### Working of batch-redis policy:
Instead of updating the shared counter in redis after each request, the request counts are maintained at a (local) node level in the shared cache (amongst nginx workers) which is synchronized with the (global) redis counter whenever a batch is complete.
Consider this scenario:

	batch-size = 500, and throughput = 1 million RPM

Each nginx worker updates the local shared cache after each request. Once the local count reaches 500 (or multiple of 500), the global redis counter is updated (by batch size). This global count (representative of total hits) is then used to update the local cache as well. And this process is repeated until the API limit is reached or the time period expires.  
Batching reduces the effective writes made on global redis counter by a factor of `batch_size`, which in this case is 500. It therefore makes the rate limiting faster (as network calls are avoided on each request), and highly scalable.  

However, Batching also introduces an error margin of `batch_size * number of instances` since the local count is used to check if request should be allowed or not and it can be outdated (in the worst case) by `batch_size * (number of instances - 1)` giving the above error margin. This can be mitigated by reducing the batch size to the smallest possible value (which does not put too much load on the redis datastore). In our tests we have found this error margin to be too miniscule (<0.5%). This error margin can also be accounted for while deciding the rate limit (if rate limit is 100, set it to 99 accounting upto for 1% error).
## Installation

If you're using `luarocks` execute the following:

    luarocks install scalable-rate-limiter

You will also need to enable this plugin by adding it to the list of enabled plugins using `KONG_PLUGINS` environment variable or the `plugins` key in `kong.conf`

    export KONG_PLUGINS=scalable-rate-limiter
	OR
	plugins=scalable-rate-limiter
### Parameters

| Parameter | Default  | Required | description |
| --- | --- | --- | --- |
| `second` |  | false | Maximum number of requests allowed in 1 second |
| `minute` |  | false | Maximum number of requests allowed in 1 minute |
| `hour` |  | false | Maximum number of requests allowed in 1 hour |
| `day` |  | false | Maximum number of requests allowed in 1 day |
| `limit_by` | service | true | Property to limit the requests on. (service, header) |
| `header_name` |  | true ( limit_by: header ) | The header name by which to limit the requests if limit_by is selected as header |
| `policy` | redis | true | Update redis at each request (redis) or in batches (redis-cluster)  |
| `batch_size` | 10 | true ( when policy: redis-cluster ) | Redis counters will be updated in batches of this size  |
| `redis_host` |  | true | Redis host |
| `redis_port` | 6379 | true | Redis port |
| `redis_password` |  | false | Redis password |
| `redis_connect_timeout` | 2s | true | Redis Connect Timeout |
| `redis_send_timeout` | 2s | true | Redis Send Timeout |
| `redis_read_timeout` | 2s | true | Redis Read Timeout |
| `redis_max_connection_attempts` | 2 | true | Total attempts to connect to a redis node |
| `redis_keepalive_timeout` | 30s | true | Keepalive timeout for redis connections |
| `redis_max_redirection` | 2 | true | Number of times a keys is tried when MOVED or ASK response is received from redis server |
| `redis_pool_size` | 4 | true | Pool size of redis connection pool |
| `redis_backlog` | 0 | true | Size of redis connection pool backlog  queue|
| `error_message` | API rate limit exceeded | true | Error message sent when rate limit is exhausted |

### Running Unit Tests

TBD
