#!/usr/bin/env lua
-- termkernel: drop the running KNUCK kernel and return to clean CraftOS.
-- Root only. Requires kernel support: exit_kernel syscall (knuck >= 1.0.18).
local ok, err = exit_kernel()
if not ok then
  io.stderr:write("termkernel: " .. tostring(err) .. "\n")
  os.exit(1)
end
-- Kernel will tear itself down on the next scheduler pass.
print("termkernel: dropping to CraftOS...")
