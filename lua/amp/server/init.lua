---@brief WebSocket server for Amp Neovim plugin
local logger = require("amp.logger")
local tcp_server = require("amp.server.tcp")

local M = {}

---@class ServerState
---@field server table|nil The TCP server instance
---@field port number|nil The port server is running on
---@field auth_token string|nil The authentication token for validating connections
---@field clients table<string, WebSocketClient> A list of connected clients
---@field ping_timer table|nil Timer for sending pings
---@field event_listeners table<string, function[]> Event listeners by event name
M.state = {
	server = nil,
	port = nil,
	auth_token = nil,
	clients = {},
	ping_timer = nil,
	event_listeners = {},
}

---Register a callback for an event
---@param event_name string The name of the event to listen for
---@param callback function The callback function to call when the event occurs
function M.on(event_name, callback)
	local listeners = M.state.event_listeners[event_name] or {}
	table.insert(listeners, callback)
	M.state.event_listeners[event_name] = listeners
end

---Remove a callback for an event
---@param event_name string The name of the event
---@param callback function The callback function to remove
function M.off(event_name, callback)
	local listeners = M.state.event_listeners[event_name] or {}
	for i = #listeners, 1, -1 do
		if listeners[i] == callback then
			table.remove(listeners, i)
		end
	end
end

---Emit an event to all registered listeners
---@param event_name string The name of the event to emit
---@param ... any Arguments to pass to the event listeners
function M._emit(event_name, ...)
	local listeners = M.state.event_listeners[event_name] or {}
	for _, callback in ipairs(listeners) do
		callback(...)
	end
end

---Initialize the WebSocket server
---@param auth_token string|nil The authentication token for validating connections
---@return boolean success Whether server started successfully
---@return number|string port_or_error Port number or error message
function M.start(auth_token)
	if M.state.server then
		return false, "Server already running"
	end

	M.state.auth_token = auth_token

	-- Log authentication state
	if auth_token then
		logger.debug("server", "Starting IDE WebSocket server with authentication enabled")
		logger.debug("server", "Auth token length:", #auth_token)
	else
		logger.debug("server", "Starting IDE WebSocket server WITHOUT authentication (insecure)")
	end

	local callbacks = {
		on_message = function(client, message)
			M._handle_message(client, message)
		end,
		on_connect = function(client)
			M.state.clients[client.id] = client

			-- Log connection with auth status
			if M.state.auth_token then
				logger.debug("server", "IDE client connected:", client.id)
			else
				logger.debug("server", "IDE client connected (no auth):", client.id)
			end

			-- Emit client connect event
			M._emit("client_connect", client)
			-- Send initial state to newly connected client
			vim.defer_fn(function()
				M._send_state()
			end, 50)
		end,
		on_disconnect = function(client, code, reason)
			M.state.clients[client.id] = nil
			logger.debug(
				"server",
				"IDE client disconnected:",
				client.id,
				"(code:",
				code,
				", reason:",
				(reason or "N/A") .. ")"
			)

			-- Emit client disconnect event
			M._emit("client_disconnect", client, code, reason)
		end,
		on_error = function(error_msg)
			logger.error("server", "IDE server error:", error_msg)

			-- Emit server error event
			M._emit("server_error", error_msg)
		end,
	}

	local server, error_msg = tcp_server.create_server(callbacks, M.state.auth_token)
	if not server then
		return false, error_msg or "Unknown server creation error"
	end

	M.state.server = server
	M.state.port = server.port

	M.state.ping_timer = tcp_server.start_ping_timer(server, 30000) -- Start ping timer to keep connections alive

	return true, server.port
end

---Replace the auth token used to validate new connections.
---Established connections are unaffected.
---@param auth_token string The new authentication token
function M.set_auth_token(auth_token)
	M.state.auth_token = auth_token
	if M.state.server then
		M.state.server.auth_token = auth_token
	end
end

---Stop the WebSocket server
---@return boolean success Whether server stopped successfully
---@return string|nil error_message Error message if any
function M.stop()
	if not M.state.server then
		return false, "Server not running"
	end

	if M.state.ping_timer then
		M.state.ping_timer:stop()
		M.state.ping_timer:close()
		M.state.ping_timer = nil
	end

	tcp_server.stop_server(M.state.server)

	M.state.server = nil
	M.state.port = nil
	M.state.auth_token = nil
	M.state.clients = {}
	M.state.event_listeners = {}

	return true
end

---Handle incoming IDE protocol message
---@param client table The client that sent the message
---@param message string The JSON message
function M._handle_message(client, message)
	local success, parsed = pcall(vim.json.decode, message)
	if not success then
		M.send_response(client, nil, nil, {
			code = -32700,
			message = "Parse error",
			data = "Invalid JSON",
		})
		logger.warn("server", "IDE client", client.id, "sent invalid JSON:", message)
		return
	end

	if type(parsed) ~= "table" then
		M.send_response(client, parsed.id, nil, {
			code = -32600,
			message = "Invalid Request",
			data = "Not a valid request",
		})
		return
	end

	local request = parsed.clientRequest
	if not request then
		logger.warn("server", "IDE client", client.id, "sent message without clientRequest")
		return
	end

	local id = request.id
	if not id then
		logger.warn("server", "IDE client", client.id, "sent request without id")
		return
	end

	local ide = require("amp.ide")

	-- Handle ping request
	if request.ping then
		local response = ide.wrap_response(id, {
			ping = { message = request.ping.message },
		})
		M.send_ide(client, response)
		return
	end

	-- Handle authenticate request
	if request.authenticate then
		local response = ide.wrap_response(id, {
			authenticate = { authenticated = true },
		})
		M.send_ide(client, response)
		return
	end

	-- Handle readFile request
	if request.readFile then
		local requested_path = request.readFile.path

		if not requested_path then
			local error_response = ide.wrap_error(id, {
				code = -32602,
				message = "Invalid params",
				data = "readFile requires path parameter",
			})
			M.send_ide(client, error_response)
			return
		end

		-- Read file contents, preferring buffer data (with unsaved changes) over disk
		local success, content = pcall(function()
			-- Normalize path to absolute path
			local full_path = vim.fn.fnamemodify(requested_path, ":p")

			-- First check if file is open in a buffer
			local bufnr = vim.fn.bufnr(full_path)
			if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
				-- Return buffer contents (including unsaved changes)
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				return table.concat(lines, "\n")
			end

			-- Fall back to reading from disk
			local uv = vim.loop
			local fd = uv.fs_open(full_path, "r", 438) -- 438 = 0666 in decimal
			if not fd then
				error("File not found or cannot be opened")
			end

			local stat = uv.fs_fstat(fd)
			if not stat then
				uv.fs_close(fd)
				error("Cannot stat file")
			end

			local data = uv.fs_read(fd, stat.size, 0)
			uv.fs_close(fd)

			if not data then
				error("Cannot read file")
			end

			return data
		end)

		if success then
			local response = ide.wrap_response(id, {
				readFile = {
					success = true,
					content = content,
					encoding = "utf-8",
				},
			})
			M.send_ide(client, response)
		else
			local response = ide.wrap_response(id, {
				readFile = {
					success = false,
					message = content, -- error message
				},
			})
			M.send_ide(client, response)
		end
		return
	end

	-- Handle editFile request
	if request.editFile then
		local path = request.editFile.path
		local fullContent = request.editFile.fullContent

		if not path then
			local error_response = ide.wrap_error(id, {
				code = -32602,
				message = "Invalid params",
				data = "editFile requires path parameter",
			})
			M.send_ide(client, error_response)
			return
		end

		if not fullContent then
			local error_response = ide.wrap_error(id, {
				code = -32602,
				message = "Invalid params",
				data = "editFile requires fullContent parameter",
			})
			M.send_ide(client, error_response)
			return
		end

		local success, error_msg = pcall(function()
			-- Normalize path to absolute path
			local full_path = vim.fn.fnamemodify(path, ":p")

			-- Get or create buffer for this file
			local bufnr = vim.fn.bufnr(full_path, true) -- create if doesn't exist

			-- If buffer not loaded, load it to respect file settings
			if not vim.api.nvim_buf_is_loaded(bufnr) then
				vim.fn.bufload(bufnr)
			end

			-- Split content into lines, preserving empty lines
			local lines = vim.split(fullContent, "\n")

			-- Remove trailing empty string if content ended with newline
			-- (nvim_buf_set_lines expects no trailing empty for final newline)
			if #lines > 0 and lines[#lines] == "" then
				table.remove(lines)
			end

			-- Replace entire buffer content
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

			-- Use async file writing with vim.loop
			local uv = vim.loop
			local fd = uv.fs_open(full_path, "w", 438) -- 438 = 0666 in decimal
			if not fd then
				error("Cannot open file for writing")
			end

			-- Ensure file ends with newline (standard POSIX convention)
			local content_to_write = fullContent
			if content_to_write:sub(-1) ~= "\n" then
				content_to_write = content_to_write .. "\n"
			end

			uv.fs_write(fd, content_to_write, 0)
			uv.fs_close(fd)

			-- Mark buffer as not modified since we just saved it
			vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
		end)

		if success then
			local response = ide.wrap_response(id, {
				editFile = {
					success = true,
					message = "Edit applied successfully to " .. path,
					appliedChanges = true,
				},
			})
			M.send_ide(client, response)
		else
			local response = ide.wrap_response(id, {
				editFile = {
					success = false,
					message = tostring(error_msg), -- ensure error message is string
				},
			})
			M.send_ide(client, response)
		end
		return
	end

	-- Handle getDiagnostics request
	if request.getDiagnostics then
		local path = request.getDiagnostics.path

		if not path then
			local error_response = ide.wrap_error(id, {
				code = -32602, -- JSON-RPC 2.0: Invalid params
				message = "Invalid params",
				data = "getDiagnostics requires path parameter",
			})
			M.send_ide(client, error_response)
			return
		end

		local diagnostics = require("amp.diagnostics")
		local entries = diagnostics.get_diagnostics(path)

		local response = ide.wrap_response(id, {
			getDiagnostics = {
				entries = entries,
			},
		})
		M.send_ide(client, response)
		return
	end

	-- Handle openURI request
	if request.openURI then
		local uri = request.openURI.uri

		if not uri then
			local error_response = ide.wrap_error(id, {
				code = -32602,
				message = "Invalid params",
				data = "openURI requires uri parameter",
			})
			M.send_ide(client, error_response)
			return
		end

		-- Only support file:// URIs for now
		if not vim.startswith(uri, "file://") then
			local response = ide.wrap_response(id, {
				openURI = {
					success = false,
					message = "Unsupported URI scheme: " .. uri,
				},
			})
			M.send_ide(client, response)
			return
		end

		local success, error_msg = pcall(function()
			-- Convert file:// URI to path
			local path = uri:gsub("^file://", "")
			-- Decode URL-encoded characters (e.g., %20 -> space)
			path = path:gsub("%%(%x%x)", function(hex)
				return string.char(tonumber(hex, 16))
			end)
			-- Normalize to absolute path (resolves .. components)
			path = vim.fn.fnamemodify(path, ":p")

			-- Check if file exists
			local stat = vim.loop.fs_stat(path)
			if not stat then
				error("File not found: " .. path)
			end

			-- Open the file in Neovim
			vim.cmd("edit " .. vim.fn.fnameescape(path))
		end)

		if success then
			local response = ide.wrap_response(id, {
				openURI = {
					success = true,
					message = "Opened " .. uri,
				},
			})
			M.send_ide(client, response)
		else
			local response = ide.wrap_response(id, {
				openURI = {
					success = false,
					message = tostring(error_msg),
				},
			})
			M.send_ide(client, response)
		end
		return
	end

	-- Unknown request
	local error_response = ide.wrap_error(id, {
		code = -32601,
		message = "Method not found",
		data = "Unknown IDE request method",
	})
	M.send_ide(client, error_response)
end

---Send IDE protocol message to a specific client
---@param client table The client to send to
---@param data table The IDE protocol message
---@return boolean success Whether message was sent successfully
function M.send_ide(client, data)
	if not M.state.server then
		return false
	end

	local json_message = vim.json.encode(data)
	tcp_server.send_to_client(M.state.server, client.id, json_message)
	return true
end

---Broadcast IDE notification to all connected clients
---@param notification table The notification data
---@return boolean success Whether broadcast was successful
function M.broadcast_ide(notification)
	if not M.state.server then
		return false
	end

	local ide = require("amp.ide")
	local message = ide.wrap_notification(notification)
	local json_message = vim.json.encode(message)

	for client_id, client in pairs(M.state.clients) do
		tcp_server.send_to_client(M.state.server, client_id, json_message)
	end
	return true
end

---Get server status information
---@return table status Server status information
function M.get_status()
	if not M.state.server then
		return {
			running = false,
			port = nil,
			client_count = 0,
		}
	end

	return {
		running = true,
		port = M.state.port,
		client_count = tcp_server.get_client_count(M.state.server),
		clients = tcp_server.get_clients_info(M.state.server),
	}
end

---Send current state to clients
function M._send_state()
	-- Force broadcast current state - the client will receive it since they just connected
	local visible_files = require("amp.visible_files")
	visible_files.broadcast_visible_files(true)

	local selection = require("amp.selection")
	selection.update_and_broadcast(true)
end

return M
