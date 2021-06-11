# scalable-rate-limiter

- [scalable-rate-limiter](#scalable-rate-limiter)
  - [Overview](#overview)
  - [Internal Working](#internal-working)
  - [Installation](#installation)
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
