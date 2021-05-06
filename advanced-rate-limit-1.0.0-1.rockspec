package = "advanced-rate-limiting"

version = "1.0.0-1"   

supported_platforms = {"linux", "macosx"}
source = {
  url = "https://github.com/dream11/kong-plugins"
}
description = {
  summary = "Rate limiting plugin for d11-kong"
}
dependencies = {
}
build = {
  type = "builtin",
  modules = {
    ["kong.plugins.advanced-rate-limiting.handler"] = "kong/plugins/advanced-rate-limiting/handler.lua",
    ["kong.plugins.advanced-rate-limiting.schema"] = "kong/plugins/advanced-rate-limiting/schema.lua",
    ["kong.plugins.advanced-rate-limiting.daos"] = "kong/plugins/advanced-rate-limiting/daos.lua",
    ["kong.plugins.advanced-rate-limiting.expiration"] = "kong/plugins/advanced-rate-limiting/expiration.lua",
    ["kong.plugins.advanced-rate-limiting.policies"] = "kong/plugins/advanced-rate-limiting/policies/init.lua",
    ["kong.plugins.advanced-rate-limiting.policies.connection"] = "kong/plugins/advanced-rate-limiting/policies/connection.lua",

    ["resty.rediscluster"] = "resty-redis-cluster/rediscluster.lua",
    ["resty.xmodem"] = "resty-redis-cluster/xmodem.lua"
  },
  copy_directories = { "migrations", "policies" }
}