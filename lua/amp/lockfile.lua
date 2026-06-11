local M = {}

-- Get the user's home directory. The fallback handles edge cases where
-- vim.loop.os_homedir() returns nil (missing HOME/USERPROFILE env vars,
-- broken containers, permission issues), but this is unlikely without
-- bigger system problems.
local function homedir()
	return vim.loop.os_homedir() or vim.fn.expand("~")
end

-- Resolve the base data directory following amp repository pattern
local function get_data_home()
	-- Optional override for testing/debugging
	local override = os.getenv("AMP_DATA_HOME")
	if override and override ~= "" then
		return override
	end

	local sys = vim.loop.os_uname().sysname
	local standard_dir = vim.fs.joinpath(homedir(), ".local", "share")

	-- Match amp repository core/src/common/dirs.ts logic:
	-- On Windows/macOS: use standard dir (~/.local/share)
	-- On Linux: use XDG_DATA_HOME if set, otherwise standard dir
	if sys == "Windows_NT" or sys == "Darwin" then
		return standard_dir
	else
		-- Linux/Unix: respect XDG if provided, fallback to standard dir
		local xdg = os.getenv("XDG_DATA_HOME")
		if xdg and xdg ~= "" then
			return xdg
		end
		return standard_dir
	end
end

local function lock_dir_base()
	return vim.fs.joinpath(get_data_home(), "amp", "ide")
end

-- Read cryptographically secure random bytes.
-- Uses libuv's uv.random (getrandom/getentropy/CryptGenRandom) and falls
-- back to /dev/urandom. Errors out rather than degrading to weak randomness.
local function random_bytes(n)
	local uv = vim.loop

	if uv.random then
		local bytes = uv.random(n)
		if type(bytes) == "string" and #bytes == n then
			return bytes
		end
	end

	local file = io.open("/dev/urandom", "rb")
	if file then
		local bytes = file:read(n)
		file:close()
		if type(bytes) == "string" and #bytes == n then
			return bytes
		end
	end

	error("No secure random source available (uv.random and /dev/urandom both failed)")
end

-- Generate a cryptographically random authentication token (64 hex chars,
-- 256 bits of entropy). Hex is URL-safe for the auth query parameter.
function M.generate_auth_token()
	local bytes = random_bytes(32)
	local hex = {}
	for i = 1, #bytes do
		hex[i] = string.format("%02x", bytes:byte(i))
	end
	return table.concat(hex)
end

-- Check whether a process with the given pid is still running
local function pid_alive(pid)
	if type(pid) ~= "number" or pid <= 0 then
		return false
	end
	local ok, err = vim.loop.kill(pid, 0)
	-- Success means the process exists; EPERM means it exists but is owned
	-- by another user. Only ESRCH (no such process) means it's gone.
	return ok ~= nil or (type(err) == "string" and not err:find("ESRCH"))
end

-- Remove lockfiles left behind by crashed/killed Neovim sessions so their
-- auth tokens don't linger on disk indefinitely.
local function cleanup_stale_lockfiles(lock_dir)
	local handle = vim.loop.fs_scandir(lock_dir)
	if not handle then
		return
	end

	while true do
		local name, entry_type = vim.loop.fs_scandir_next(handle)
		if not name then
			break
		end

		if entry_type == "file" and name:match("%.json$") then
			local path = vim.fs.joinpath(lock_dir, name)
			local file = io.open(path, "r")
			if file then
				local content = file:read("*a")
				file:close()

				local ok, data = pcall(vim.json.decode, content)
				if not ok or type(data) ~= "table" or not pid_alive(data.pid) then
					os.remove(path)
				end
			end
		end
	end
end

-- Create a lock file with port and auth token.
-- The lock directory is created with 0700 and the lockfile with 0600 so the
-- cleartext auth token is only readable by the current user.
function M.create(port, auth_token)
	local uv = vim.loop
	local lock_dir = lock_dir_base()
	local lockfile_path = vim.fs.joinpath(lock_dir, tostring(port) .. ".json")

	-- Create directory structure if it doesn't exist
	local mkdir_success = vim.fn.mkdir(lock_dir, "p", "0700")
	if mkdir_success == 0 then
		return false, "Could not create lock directory: " .. lock_dir
	end

	-- Tighten permissions on a pre-existing directory
	uv.fs_chmod(lock_dir, 448) -- 0700

	cleanup_stale_lockfiles(lock_dir)

	-- Create the lock file with user-only permissions (0600)
	local fd = uv.fs_open(lockfile_path, "w", 384) -- 0600
	if not fd then
		return false, "Could not create lock file: " .. lockfile_path
	end

	-- Update permissions on pre-existing lockfile
	uv.fs_fchmod(fd, 384) -- 0600

	-- Get current working directory and nvim version info
	local cwd = vim.fn.getcwd()
	local version = vim.version()
	local ide_name = string.format("nvim %d.%d.%d", version.major, version.minor, version.patch)

	local lock_data = {
		port = port,
		authToken = auth_token,
		pid = vim.fn.getpid(),
		workspaceFolders = { cwd },
		ideName = ide_name,
	}

	uv.fs_write(fd, vim.json.encode(lock_data), 0)
	uv.fs_close(fd)

	return true, lockfile_path
end

-- Remove a lock file
function M.remove(port)
	if not port then
		return false, "No port specified"
	end

	local lockfile_path = vim.fs.joinpath(lock_dir_base(), tostring(port) .. ".json")
	local success = os.remove(lockfile_path)

	return success ~= nil, success and "Lock file removed" or "Could not remove lock file"
end

return M
