local PLUGIN_NAME = "scalable-rate-limiter"

-- helper function to validate data against a schema
local validate
do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins." .. PLUGIN_NAME .. ".schema")

  function validate(data)
    return validate_entity(data, plugin_schema)
  end
end


describe(PLUGIN_NAME .. ": (schema)", function()
  it("validate schema", function()
    local config = {
      limit_by = "consumer",
      limit_by_consumer_config = "{\"consumer1\": {\"hour\": 15  },\"consumer2\": {\"hour\": 16  }}",
      header_name = "X-Consumer-Username",
      redis_host = "redis.host"
    }

    local ok, err = validate(config)

    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

  it("validate schema - consumer limit by - negative", function()
    local config = {
      limit_by = "consumer",
      error_message = "API rate limit exceeded",
      redis_host = "redis.host"
    }

    local ok, err = validate(config)

    assert.same("required field missing", err.config.header_name)
    assert.same("required field missing", err.config.limit_by_consumer_config)
  end)

  it("validate schema - consumer limit by - invalid json string in limit_by_consumer_config", function()
    local config = {
      limit_by = "consumer",
      error_message = "API rate limit exceeded",
      redis_host = "redis.host",
      limit_by_consumer_config = "invalid json content",
    }

    local ok, err = validate(config)

    assert.is_nil(ok)
    assert.is_not_nil(err)
  end)
end)
