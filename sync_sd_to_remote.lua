#!/usr/bin/lua

--[[
 Written by Alon Levy

 This file is in the public domain. It's been mostly a learning experience with
 lua and it is not very pretty. I hope it will be some help to someone
 nontheless!

TODO:
 - all file writing must be checked for errors (open, write, read)
 - if card is not accessed, send server a notification
  - ssh echo "could not read card <DATE> - not seeing wifi/http error/other reason" > TARGET_PATH/logger_error.txt
 - if any fails, fallback to syncing all files without caching test
 - use a single file for all cache, write a line per file in it (can sort it and then can do search on it)

]]


local socket = require("socket")
local posix = require("posix")
local os = require('oswrap') -- cannot require os, it is a hard coded module, not looked up in package.path (could fix this with a C written tester)
local io = require('iowrap')
local fa_sync = require('fa_sync')

local module = {}

-- Development defaults, use sdcardemul.py as the server.
SDCARD_HOST = "127.0.0.1"
SDCARD_PORT = 8000
TARGET_PATH = "/home/flashair/data-logger"
SYNC_DIR = "/tmp/sync"
SSH_OPTS = ""
SSH_USER = 'flashair'
SSH_HOST = 'localhost'
FIFO = "/tmp/fifo"
DEBUG = false

-- http (socket.http) produces "Malformed request" errors with the sd httpd server,
-- so just use socket directly.

-- We open a fifo so we must background it or be blocked.
function background_write(filename, text)
    local pid, err = posix.fork()
    assert(pid ~= nil, "fork() failed")
    if pid == 0 then
        local f = io.open(filename, "w")
        f:write(text)
        f:close()
        posix._exit(0)
        return
    end
    return pid
end

-- Note: previous version used popen3, avoiding the need for the fifo. But the
-- openwrt's luaposix package doesn't support popen and dup2. This works just as well.
function pipe_simple(input, cmd)
    os.execute('[ ! -e ' .. FIFO .. ' ] && mkfifo ' .. FIFO)
    local pid = background_write(FIFO, input)
    local success, reason, status = os.execute(cmd .. ' < ' .. FIFO)
    DEBUGP(function () return string.format("pid = %s", pid) end)
    posix.wait(pid)
    DEBUGP(function () return string.format("status = %s; success = %s; reason = %s", status, success, reason) end)
    if success == 0 then
        return 0
    else
        return status
    end
end


-- Compatibility: Lua-5.1
function split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
         table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end

-- The socket.http module isn't liked by the Air card httpd, so just copy the headers
-- from wget.
function sdget_stream(path)
	s = socket.connect(SDCARD_HOST, SDCARD_PORT)
    assert(s ~= nil, "failed to connect to sd card")
    request = ('GET ' .. path .. ' HTTP/1.1\r\n' ..
               'User-Agent: curl/7.40.0\r\n' ..
               'Host: ' .. SDCARD_HOST .. '\r\n' ..
               'Accept: */*\r\n' ..
               --'Connection: Keep-Alive\r\n' ..
               '\r\n')
    -- print(request .. '\n\n')
	s:send(request)
    return s
end

-- Skip HTTP headers. exercise in writing a state machine in lua.
--
-- Could be replaced with
-- the following if you have the memory for the whole HTTP response:
--
-- _, header_end = body:find('\r\n\r\n')
-- return body:sub(header_end + 1)
function skip_headers(s)
    local found = 0
    local headers = {}
    local state = "1"
    while found == 0 do
        -- print("state: " .. state .. "; reading 1")
        body = s:receive(1)
        if body == nil then
            break
        end
        headers[#headers + 1] = body
        if state == "1" then
            if body == "\r" then
                state = "2"
            else
                state = "1"
            end
        elseif state == "2" then
            if body == "\n" then
                state = "3"
            else
                state = "1"
            end
        elseif state == "3" then
            if body == "\r" then
                state = "4"
            else
                state = "1"
            end
        elseif state == "4" then
            if body == "\n" then
                break
            else
                state = "1"
            end
        end
    end
    return table.concat(headers, "")
end


function sdget(path)
    s = sdget_stream(path)
    headers = skip_headers(s)
    -- print(headers)
	body = s:receive("*a")
    -- print(body)
	return body
end

function sd_csvfile_get(filename)
	return sdget('/CSVFILES/LOG/' .. filename)
end

-- Parse the SD Air card's http server directory listing. It contains name, size, date and time for
-- each file. date & time are not actually those, they are the top and bottom 16 bits of the seconds
-- since epoch of the file. They are only used comparitavely, so it doesn't matter.
function sd_dir_read(path)
    -- Uses command.cgi: https://www.flashair-developers.com/en/documents/api/commandcgi/
	body = sdget('/command.cgi?op=100&DIR=' .. path)
	files = {}
	for k, v in ipairs((split(body, '\n'))) do
        -- print(k .. ': ' .. v)
        if k > 1 then
            parts = split(v, ',')
            root, filename, size, whatever, date, time = parts[1], parts[2], parts[3], parts[4], parts[5], string.format('%d', parts[6])
            -- print(root .. ', ' .. filename .. ', ' .. size .. ', ' .. date .. ', ' .. time)
            if filename then
                print(filename)
                table.insert(files, {["filename"] = filename,
                    ["size"] = size, ["date"] = date, ["time"] = time})
            end
        end
	end
	return files
end

function array_concat(t1, t2)
    for i=1, #t2 do
        t1[#t1 + 1] = t2[i]
    end
    return t1
end

-- ssh file to remote, using ssh and not scp to use local stdin for the contents,
-- avoiding a temporary file (sd can be much larger then the local storage on the openwrt)
function sync(filename, contents)
    local cmd = 'ssh ' .. SSH_OPTS .. ' -l ' .. SSH_USER .. ' ' .. SSH_HOST .. ' "cat > ' .. TARGET_PATH .. '/' .. filename .. '"'
    if DEBUG then
        cmd = 'echo ' .. cmd
    end
    return pipe_simple(contents, cmd)
end

function module.main()
    -- Load config file
    if arg[1] then
        dofile(arg[1])
    end

    if DEBUG then
        _G.DEBUGP = function (f) print(string.format('DEBUG: %s', f())) end
    else
        _G.DEBUGP = function (f) end -- do nothing
    end
    print("Welcome to sync sd to remote")
    print("SD:         " .. SDCARD_HOST .. ':' .. SDCARD_PORT)
    print("SSH:        " .. SSH_USER .. ' at ' .. SSH_HOST)
    print("SSH_OPTS:   " .. SSH_OPTS)
    print("SYNC dir:   " .. SYNC_DIR)
    print("TARGET dir: " .. TARGET_PATH)
    if DEBUG then
        print("!!! DEBUG !!!")
    end

	print("starting sync")
    os.execute('mkdir -p ' .. SYNC_DIR)
	files = sd_dir_read("/CSVFILES/LOG")

    local syncer = fa_sync.Syncer(SYNC_DIR)

    local k
    local v
	for k, v in ipairs(files) do
		if not syncer:synced(v.filename, v.date, v.time) then
            print("syncing " .. v.filename .. ' (' .. v.size .. ')')
			file_body = sd_csvfile_get(v.filename)
            if sync(v.filename, file_body) ~= 0 then
                print("ERROR syncing " .. v.filename .. ", skipping it (not updating sync file)")
            else
                syncer:update(v.filename, v.date, v.time)
            end
        end
	end
	print("ended sync")
end

return module
