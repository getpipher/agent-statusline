--!strict
-- Agent Statusline — host half.
-- All data work lives here: quota pollers, deen fetch, money scanner, window
-- math (2 s budget per host call), assembled into one snapshot written to
-- tern.kv ("asl/snapshot"). The panel block
-- ("plugin.agent-statusline.panel") is defined here in a later phase.
tern.log.info("agent-statusline host loaded")
