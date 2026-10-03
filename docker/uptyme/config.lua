-- UPTYME configuration (deploy-provided, environment-aware).
--
-- The Lua sandbox strips os.getenv, and env_get only sees host variables
-- prefixed SPYWEB_ (docs.spyweb.app/security). So every knob below reads
-- SPYWEB_<KEY>: e.g. env_get("MODE") -> $SPYWEB_MODE.
--
-- Mount your own config.lua over /opt/uptyme/config.lua for full control
-- (alert channels, logging, etc).

local mode = env_get("MODE") or "standalone"  -- standalone | central | checker
local role = env_get("ROLE")                  -- central | checker (optional; overrides mode)

return {
    -- Logging (applies to all roles).
    -- level:  debug | info | warn | error | none
    -- output: file | terminal | both | none
    -- throttle: N = at most one log per N same-category occurrences; 0 = off
    logging = { level = "error", output = env_get("LOG_OUTPUT") or "file", throttle = 6 },

    -- Cluster mode. False = standalone, only `logging` applies.
    -- Role only takes effect when multi_node is true.
    multi_node = mode ~= "standalone" or role ~= nil,
    role = role or (mode == "checker" and "checker" or "central"),

    -- Checker-only settings (ignored unless the node is a checker).
    node_name = env_get("NODE_NAME"),
    central_url = env_get("CENTRAL_URL"),
    auth_token = env_get("AUTH_TOKEN"),

    -- Consecutive failed sync polls before "central unreachable" alert fires.
    central_alert_failures = 3,

    -- Headless: no desktop alerts. Mount your own config.lua for channels.
    checker_alerts = { desktop = false },
}
