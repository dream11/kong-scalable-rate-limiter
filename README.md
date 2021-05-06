## What is advanced-rate-limiting plugin

**Advanced-rate-limiting** is a plugin for [Kong](https://github.com/Mashape/kong) built on top of [Rate-limiting](https://docs.konghq.com/hub/kong-inc/rate-limiting/) plugin

Following changes are made to the [Rate-limiting](https://docs.konghq.com/hub/kong-inc/rate-limiting/) plugin to improve the performance:  
1. Add support for Redis cluster using [Resty-Redis-Cluster](https://github.com/steve0511/resty-redis-cluster) client.
2. Ability to Update the rate limiting metrics on redis in batches.

## How does it work
 
Issue in Kong rate-limiting plugin: For low throughput it works well with cluster (cassandra) policy.
When throughput is above 50k RPM, you will face hotkey issue and plugin's performance will degrade.
To address this problem, we have tweaked the existing code and introduced a new policy - batch-redis.
Also, since the [lua-rest-redis](https://github.com/openresty/lua-resty-redis) client does not support redis cluster we replaced it with [Resty-Redis-Cluster](https://github.com/steve0511/resty-redis-cluster). We have also made a change to [Resty-Redis-Cluster](https://github.com/steve0511/resty-redis-cluster) to make it fault taulerant.

Working of batch-redis policy:
It uses local cache as a primary data store and synchronizes with cluster (redis) data store in batches.
for eg: batch-size = 500, and throughput = 1 million RPM
It will update the local cache after every single api hit and pushes the api count to redis after every 500th api hit.
At the same time, it will sync the redis rate limit metric to a local cache.
So according to this we will be hitting cassandra writer (1000000/500) = 2000 times in a minutes.

## Installation

If you're using `luarocks` execute the following:

     luarocks install advanced-rate-limiting

You also need to set the `KONG_PLUGINS` environment variable

     export KONG_PLUGINS=advanced-rate-limiting
     
### Parameters

| Parameter | Default  | Required | description |
| --- | --- | --- | --- |
| `second` |  | false | Maximum number of requests allowed in 1 second |
| `minute` |  | false | Maximum number of requests allowed in 1 minute |
| `hour` |  | false | Maximum number of requests allowed in 1 hour |
| `day` |  | false | Maximum number of requests allowed in 1 day |
| `limit_by` |  | true | Property to limit the requests on. (consumer, credential, ip, service, header, path) |
| `header_name` |  | true ( limit_by: header ) | The header name by which to limit the requests if limit_by is selected as header |
| `policy` |  | true | Update redis at each request (redis) or in batches (redis-cluster)  |
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