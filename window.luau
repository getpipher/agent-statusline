--!strict
-- Agent Statusline — window half.
-- Zero-work chrome formatters (4 ms budget) returning prebuilt upvalues; a
-- 5 s tern.timer watches tern.kv "asl/snapshot".seq and calls
-- tern.chrome.refresh() on change. Palette commands and provider gating via
-- cx.agents:list() land in later phases.
tern.log.info("agent-statusline window loaded")
