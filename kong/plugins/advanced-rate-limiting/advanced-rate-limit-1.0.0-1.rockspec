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
    ["kong.plugins.advanced-rate-limiting.handler"] = "handler.lua",
    ["kong.plugins.advanced-rate-limiting.schema"] = "schema.lua",
    ["kong.plugins.advanced-rate-limiting.daos"] = "daos.lua",
    ["kong.plugins.advanced-rate-limiting.expiration"] = "expiration.lua",
    ["kong.plugins.advanced-rate-limiting.policies"] = "policies/init.lua",
    ["kong.plugins.advanced-rate-limiting.policies.connection"] = "policies/connection.lua",

    ["resty.rediscluster"] = "resty-redis-cluster/rediscluster.lua",
    ["resty.xmodem"] = "resty-redis-cluster/xmodem.lua"
  },
  copy_directories = { "migrations", "policies" }
}