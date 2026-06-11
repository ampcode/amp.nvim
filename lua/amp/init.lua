---@brief [[
--- Amp Neovim WebSocket Plugin
--- Demonstrates basic WebSocket server integration with Neovim
---@brief ]]

local M = {}

local logger = require("amp.logger")

--- Plugin version
M.version = {
	major = 0,
	minor = 1,
	patch = 0,
	string = function(self)
		return string.format("%d.%d.%d", self.major, self.minor, self.patch)
	end,
}

-- Plugin state
M.state = {
	config = require("amp.config").defaults,
	server = nil,
	port = nil,
	auth_token = nil,
	token_rotation_timer = nil,
	connected = false,
	initialized = false,
}

-- Rotate the auth token every hour so a leaked lockfile token has a
-- bounded lifetime. New connections use the fresh token from the
-- rewritten lockfile; established connections are unaffected.
local TOKEN_ROTATION_INTERVAL_MS = 4 * 60 * 60 * 1000

---Rotate the auth token and rewrite the lockfile
function M._rotate_auth_token()
	if not M.state.server or not M.state.port then
		return
	end

	local lockfile = require("amp.lockfile")
	local ok, new_token = pcall(lockfile.generate_auth_token)
	if not ok then
		logger.error("init", "Failed to rotate auth token: " .. tostring(new_token))
		return
	end

	local lock_success, lock_result = lockfile.create(M.state.port, new_token)
	if not lock_success then
		logger.error("init", "Failed to rewrite lock file during token rotation: " .. tostring(lock_result))
		return
	end

	M.state.server.set_auth_token(new_token)
	M.state.auth_token = new_token
	logger.debug("init", "Auth token rotated")
end

---Handle client connection event
function M._on_client_connect()
	local was_connected = M.state.connected
	M.state.connected = true

	if not was_connected then
		-- Use print() directly to avoid [INFO] init: prefix from logger
		print("● Connected to Amp CLI")
	end
end

---Handle client disconnection event
function M._on_client_disconnect()
	local was_connected = M.state.connected
	local server_status = require("amp.server.init").get_status()
	M.state.connected = server_status.client_count > 0

	if was_connected and not M.state.connected then
		logger.info("init", "Disconnected from Amp (no clients)")
	end
end

---Setup the plugin with user configuration
---@param opts table|nil Optional configuration
---@return table module The plugin module
function M.setup(opts)
	if vim.g.vscode then
		return M
	end
	opts = opts or {}

	local config = require("amp.config")
	M.state.config = config.apply(opts)

	logger.setup(M.state.config)

	if M.state.config.auto_start then
		M.start()
	end

	M._create_commands()

	-- Cleanup on exit
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("AmpPluginShutdown", { clear = true }),
		callback = function()
			if M.state.server then
				M.stop()
			end
		end,
		desc = "Automatically stop plugin when exiting Neovim",
	})

	M.state.initialized = true
	return M
end

---Start the WebSocket server
---@return boolean success
---@return number|string port_or_error
function M.start()
	if M.state.server then
		logger.warn("init", "Server is already running on port " .. tostring(M.state.port))
		return false, "Already running"
	end

	local server = require("amp.server.init")
	local lockfile = require("amp.lockfile")

	-- Generate auth token
	local auth_success, auth_token = pcall(lockfile.generate_auth_token)
	if not auth_success then
		local error_msg = "Failed to generate authentication token: " .. (auth_token or "unknown error")
		logger.error("init", error_msg)
		return false, error_msg
	end

	-- Start server
	local success, result = server.start(auth_token)
	if not success then
		local error_msg = "Failed to start server: " .. (result or "unknown error")
		logger.error("init", error_msg)
		return false, error_msg
	end

	M.state.server = server
	M.state.port = tonumber(result)
	M.state.auth_token = auth_token

	-- Register event listeners
	server.on("client_connect", M._on_client_connect)
	server.on("client_disconnect", M._on_client_disconnect)

	-- Enable IDE protocol features
	M._enable_ide_features(server)

	-- Create lock file
	local lock_success, lock_result = lockfile.create(M.state.port, auth_token)
	if not lock_success then
		server.stop()
		M.state.server = nil
		M.state.port = nil
		M.state.auth_token = nil
		M.state.connected = false

		local error_msg = "Failed to create lock file: " .. (lock_result or "unknown error")
		logger.error("init", error_msg)
		return false, error_msg
	end

	-- Periodically rotate the auth token so it isn't long-lived
	local timer = vim.loop.new_timer()
	if timer then
		timer:start(
			TOKEN_ROTATION_INTERVAL_MS,
			TOKEN_ROTATION_INTERVAL_MS,
			vim.schedule_wrap(function()
				M._rotate_auth_token()
			end)
		)
		M.state.token_rotation_timer = timer
	end

	logger.info("init", "Server started on port " .. tostring(M.state.port))
	return true, M.state.port
end

---Stop the WebSocket server
---@return boolean success
---@return string|nil error
function M.stop()
	if not M.state.server then
		logger.info("init", "Server is not running")
		return false, "Not running"
	end

	if M.state.token_rotation_timer then
		M.state.token_rotation_timer:stop()
		M.state.token_rotation_timer:close()
		M.state.token_rotation_timer = nil
	end

	local lockfile = require("amp.lockfile")
	lockfile.remove(M.state.port)

	-- Disable IDE features first
	M._disable_ide_features()

	local success, error = M.state.server.stop()
	if not success then
		logger.error("init", "Failed to stop server: " .. error)
		return false, error
	end

	M.state.server = nil
	M.state.port = nil
	M.state.auth_token = nil
	M.state.connected = false

	logger.info("init", "Server stopped")
	return true
end

---Enable IDE protocol features (selection and visible files tracking)
---@param server table The server instance
function M._enable_ide_features(server)
	-- Enable selection tracking
	local selection = require("amp.selection")
	selection.enable(server)

	-- Enable visible files tracking
	local visible_files = require("amp.visible_files")
	visible_files.enable(server)

	-- Send initial plugin metadata
	vim.defer_fn(function()
		server.broadcast_ide({
			pluginMetadata = {
				version = M.version:string(),
				pluginDirectory = vim.fn.stdpath("data") .. "/site/pack/*/start/amp.nvim",
			},
		})
	end, 200)

	logger.debug("init", "IDE protocol features enabled")
end

---Disable IDE protocol features
function M._disable_ide_features()
	local selection = require("amp.selection")
	selection.disable()

	local visible_files = require("amp.visible_files")
	visible_files.disable()

	logger.debug("init", "IDE protocol features disabled")
end

---Create user commands
function M._create_commands()
	vim.api.nvim_create_user_command("AmpStart", function()
		M.start()
	end, { desc = "Start Amp plugin server" })

	vim.api.nvim_create_user_command("AmpStop", function()
		M.stop()
	end, { desc = "Stop Amp plugin server" })

	vim.api.nvim_create_user_command("AmpStatus", function()
		if M.state.server and M.state.port then
			local connection_status = M.state.connected and "connected" or "waiting for clients"
			logger.info(
				"command",
				"Server is running on port " .. tostring(M.state.port) .. " (" .. connection_status .. ")"
			)

			-- Show current visible files and selection for debugging
			local visible_files = require("amp.visible_files")
			local current_files = visible_files.get_current_visible_files()
			logger.info("command", "Visible files count:", #current_files)
			for i, uri in ipairs(current_files) do
				if i <= 3 then
					local filename = uri:match("file://.*/(.*)")
					logger.info("command", "  " .. i .. ":", filename or uri)
				elseif i == 4 and #current_files > 3 then
					logger.info("command", "  ... and", #current_files - 3, "more files")
					break
				end
			end

			local selection = require("amp.selection")
			local current_selection = selection.get_current_selection()
			if current_selection then
				local filename = current_selection.fileUrl:match("file://.*/(.*)")
				logger.info("command", "Current selection:", filename or current_selection.fileUrl)
				logger.info(
					"command",
					"  Range: "
						.. (current_selection.selection.start.line + 1)
						.. ":"
						.. current_selection.selection.start.character
						.. " - "
						.. (current_selection.selection["end"].line + 1)
						.. ":"
						.. current_selection.selection["end"].character
				)
				if current_selection.text ~= "" then
					local preview = current_selection.text:sub(1, 50)
					if #current_selection.text > 50 then
						preview = preview .. "..."
					end
					logger.info("command", "  Text:", preview)
				end
			else
				logger.info("command", "No current selection")
			end
		else
			logger.info("command", "Server is not running")
		end

		-- Show most recent error if any
		local last_error = logger.get_last_error()
		if last_error then
			local time_str = os.date("%H:%M:%S", last_error.timestamp)
			logger.info(
				"command",
				"Last error (" .. time_str .. ") [" .. last_error.context .. "]: " .. last_error.message
			)
		else
			logger.info("command", "No recent errors")
		end
	end, { desc = "Show Amp plugin server status" })

	vim.api.nvim_create_user_command("AmpTest", function()
		if not M.state.server then
			logger.warn("command", "Server is not running - start it first with :AmpStart")
			return
		end

		logger.info("command", "Testing IDE protocol notifications...")

		-- Test selection notification
		local selection = require("amp.selection")
		selection.update_and_broadcast()

		-- Test visible files notification
		local visible_files = require("amp.visible_files")
		visible_files.broadcast_visible_files()

		-- Test plugin metadata notification
		M.state.server.broadcast_ide({
			pluginMetadata = {
				version = M.version:string(),
				pluginDirectory = vim.fn.stdpath("data") .. "/site/pack/*/start/amp.nvim",
			},
		})

		logger.info("command", "IDE notifications sent!")
	end, { desc = "Test Amp IDE protocol notifications" })
end

return M
