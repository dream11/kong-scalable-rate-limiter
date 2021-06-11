[![Continuous Integration](https://github.com/dream11/kong-circuit-breaker/actions/workflows/ci.yml/badge.svg)](https://github.com/dream11/kong-circuit-breaker/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-green.svg)

## Overview
`kong-circuit-breaker` is a Kong plugin that provides circuit-breaker functionality at the route level. It uses [lua-circuit-breaker](https://github.com/dream11/lua-circuit-breaker) library internally to wrap proxy calls around a circuit-breaker pattern. The functionality provided by this plugin is similar to libraries like [resilience4j](https://github.com/resilience4j/resilience4j) in Java.

## Usecase
In high throughput use cases, if an API of an upstream service results in timeouts/failures, the following will happen:
1. It will bring a cascading failure effect to Kong and reduce its performance
2. Continued calls to upstream service (which is facing downtime) will prevent the upstream service from recovering
Thus, it is essential for proxy calls made from Kong to fail fast using an intelligent configurable mechanism, leading to improved resiliency and fault tolerance.

## Behaviour
The circuit breaker works like an electric circuit breaker only as it has three states:
1. Open: The CB will not allow any requests to this route, and it will fail fast.
2. Half-open: The CB will allow few requests to this route based on the configuration to check if it fails or passes.
3. Closed: All requests will work as usual.


## How does it work?
Internally, the plugin uses [lua-circuit-breaker](https://github.com/dream11/lua-circuit-breaker) library to wrap proxy calls made by Kong with a circuit-breaker.
1. To decide whether a route is in a healthy/unhealthy state, success % and failure % are calculated in a time window of `window_time` seconds.
2. For any calculation to happen in step 1, the total number of requests in the time window should >= `min_calls_in_window`.
3. If failure % calculated crosses `failure_percent_threshold` circuit is opened. This prevents any more calls to this route until `wait_duration_in_open_state seconds` have elapsed. After this, the circuit transitions to the half-open state automatically
4. In the half-open state, when `total_requests` >= `half_open_min_calls_in_window`, failure % is calculated to resolve circuit-breaker into the open or the closed state.
5. If the circuit-breaker cannot resolve the state in the `wait_duration_in_half_open_state` seconds, it automatically transitions into the closed state.


## Installation

### [luarocks](https://luarocks.org/modules/dream11/kong-circuit-breaker)
```bash
luarocks install kong-circuit-breaker
```

### source
Clone this repo and run:
```
luarocks make
```

## Usage
```lua
conf = {
    version = 0,
    window_time = 15,
    min_calls_in_window = 20,
    api_call_timeout_ms = 500,
    failure_percent_threshold = 51,
    wait_duration_in_open_state = 15,
    wait_duration_in_half_open_state = 180,
    error_status_code = 599
}
```
You can add this plugin on a global / service / route level in Kong API Gateway.

* Lets say you add this plugin at a global-level with conf, this will create a CB object for each route.
* If you want to exclude some routes from being wrapped with CB then use `conf.excluded_apis`.
* If you want to override the configuration of global-level CB for a route (say ```GET /test```), then enable this plugin for ```GET /test``` route also with a different conf.


### Parameters

| Key | Default  | Type  | Required | Description |
| --- | --- | --- | --- | --- |
| version | 0 | number | true | Version of plugin's configuration |
| window_time | 10 | number | true | Window size in seconds |
| api_call_timeout_ms |  2000 | number | true | Duration to wait before request is timed out and counted as failure |
| min_calls_in_window | 20 | number | true | Minimum number of calls to be present in the window to start calculation |
| failure_percent_threshold | 51 | number | true | % of requests that should fail to open the circuit |
| wait_duration_in_open_state | 15 | number | true | Duration(sec) to wait before automatically transitioning from open to half-open state |
| wait_duration_in_half_open_state | 120 | number | true | Duration(sec) to wait in half-open state before automatically transitioning to closed state |
| half_open_min_calls_in_window | 5 | number | true | Minimum number of calls to be present in the half open state to start calculation |
| half_open_max_calls_in_window | 10 | number | true | Maximum calls to allow in half open state |
| error_status_code | 599 | number | false | Override response status code in case of error (circuit-breaker blocks the request) |
| error_msg_override | nil | string | false | Override with custom message in case of error |
| response_header_override | nil | string | false | Override "Content-Type" response header in case of error |
| excluded_apis | "{\"GET_/kong-healthcheck\": true}" | string | true | Stringified json to prevent running circuit-breaker on these APIs |
| set_logger_metrics_in_ctx | true | boolean | false | Set circuit-breaker events in kong.ctx.shared to be consumed by other plugins like logger |

## Caveats

1. Circuit breaker uses time window to count failures, successes, and total_requests. These windows are not sliding, i.e., if you create a window of 10 seconds, it will create windows like:
```
    window_1 (  0s - 10s ),
    window_2 ( 10s - 20s ),
    window_3 ( 20s - 30s ) ...
```
2. Circuit-breaker object is created for each route in each nginx worker. The state of CB object (like counters) is never shared among workers. While setting the configuration, carefully set parameters like `min_calls_in_window` taking total nginx workers into account.
3. Circuit breaker uses failure % to figure out if a route is healthy or not. Always set `min_calls_in_window` to start calculations; else, you may open the circuit when total_requests are relatively low.
4. Set `half_open_max_calls_in_window` to prevent allowing too many requests to the route in the half-open state.
5. `set_logger_metrics_in_ctx` sets circuit_breaker_name, upstream_service_host and circuit_breaker_state in `kong.ctx.shared.logger_metrics.circuit_breaker`. You can later use this data within context of a request to log these events.
6. `version` helps in recreating a new circuit-breaker object for a route if `conf_new.version > conf_old.version`, so whenever you change the plugin configuration, increment the version for changes to take effect.

## Inspired by
- [lua-circuit-breaker](https://github.com/dream11/lua-circuit-breaker)
- [resilience4j](https://github.com/resilience4j/resilience4j)

# scalable-rate-limiter

- [scalable-rate-limiter](#scalable-rate-limiter)
    - [Overview](#overview-1)
    - [Internal Working](#internal-working)
    - [Installation](#installation-1)
    - [Configuration](#configuration)
    - [Development](#development)

## Overview

scalable-rate-limiter is a custom plugin for d11-kong API gateway built on top of rate-limiting kong plugin.\
Follow this blog for details: https://docs.konghq.com/hub/kong-inc/rate-limiting/

1. for high throughput apis (more than 20k rpm) use batch-cluster (cassandra) policy and keep batch size = 500
2. for low throughput apis use cluster policy, batch size = 1 (default and always)


## Internal Working
Issue in kong rate-limiting plugin:
For low throughput it works well with cluster (cassandra) policy.\
When throughput is above 50k RPM, you will face hotkey issue. Data will be inconsistent and rate-limiting plugin performance will degrade.\
To address this problem, we have tweaked the existing code and introduced a new policy - batch-cluster.

Working of batch-cluster mode:\
It uses local cache as a primary data store and sync with cluster (cassandra) data store in batches.\
for eg: batch-size = 500, and throughput = 1 million RPM\
It will update the local cache after every single api hit and pushes the api count to cassandra after every 500th api hit.\
At the same time, it will sync the cassandra rate limit metric to a local cache.\
So according to this we will be hitting cassandra writer (1000000/500) = 2000 times in a minutes.


## Installation

`For development env`: You need to load this plugin when starting kong in local machine using gojira. Then you can add this plugin to routes using Konga dashboard or using Kong's Admin APIs.
```
KONG_PLUGINS=bundled,scalable-rate-limiter gojira up --cassandra --volume /Users/santosh.nain/work/backend/d11-kong/plugins/:/kong-plugin/kong/plugins/ --port 0.0.0.0:8000:8000/tcp --port 0.0.0.0:8001:8001/tcp
```

`For production env`: Plugin will already be loaded for use in routes. Just add it to your route, configure it the right way and you are good to go.


## Configuration

1. `batch-cluster`: select this policy when you want to use the combination of local cache and cluster.
2. `batch-size`: default=10, works only when batch-cluster policy is selected.
3. `cluster`: select this policy when you want to save your rate limit metrics on cassandra db.
4. `redis`: select this policy when you want to save your rate limit metrics on redis db.
5. `local`: select this policy when you want to save your rate limit metrics on local cache.


## Development

scalable-rate-limiter is currently in development. The latest released version is 1.0.0\
Load Test results: https://dream11.atlassian.net/wiki/spaces/TECH/pages/1209008229/Kong+Rate-limiting+plugin+load+test
