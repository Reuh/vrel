#!/bin/lua
--- vrel v0.1.3: online paste service, in 256 lines of Lua (max line lenght = 256 but we shouldn't go this far if not needed).
-- This module requires LuaSocket 2.0.2, and debug mode requires LuaFileSystem 1.6.3. Install pygmentize for the optional syntax highlighting.
-- If you want persistance for paste storage, install lsqlite3. vrel should work with Lua 5.1 to 5.3.
-- Basic HTTP server --
local httpd, requestMaxDataSize = nil, 15728640 -- max post data size (bytes) (15MB)
httpd = {
	log = function(str, ...) print("["..os.date().."] "..str:format(...)) end, -- log a message (str:format(...))
	peername = function(client) return ("%s:%s"):format(client:getpeername()) end, -- returns a nice display name for the client (address:port)
	unescape = function(txt) return require("socket.url").unescape(txt:gsub("+", " ")) end, -- unescape URL-encoded stuff
	parseArgs = function(args) -- parse GET or POST arguments and returns the corresponding table {argName=argValue,...} (strings)
		local out = {}
		for arg in (args.."&"):gmatch("([^&]+)%&") do
			local name, value = arg:match("^(.*)%=(.*)$")
			out[httpd.unescape(name)] = httpd.unescape(value)
		end
		return out
	end,
	getRequest = function(client) -- retrieve and parse an HTTP request, and returns the corresponding Request object (or nil,errorString)
		local request = { -- Request object
			client = client, -- client object (tcp socket)
			method = "GET", -- HTTP method
			path = "/", -- requested path
			version = "HTTP/1.1", -- HTTP version string
			headers = {}, -- headers table: {headerName=headerValue,...} (strings)
			body = "", -- request body
			post = {}, -- POST args {argName=argValue,...} (strings)
			get = {} -- GET args {argName=argValue,...} (strings)
		}
		-- Get headers data from socket
		local lines = {}
		repeat
			local message = client:receive("*l")
			table.insert(lines, message)
		until not message or #message == 0
		-- Parse fisrt line (method, path and HTTP version)
		request.method, request.path, request.version = lines[1]:match("(%S*)%s(%S*)%s(%S*)")
		if not request.method then return nil, "malformed request" end
		-- Parse headers
		for i=2, #lines, 1 do
			local l = lines[i]
			local name, value = l:match("^(.-)%:%s(.*)$")
			if name and value then request.headers[name] = value
			elseif #l == 0 then break
			else return nil, "malformed headers" end
		end
		if request.headers["Expect"] == "100-continue" then client:send("HTTP/1.1 100 Continue\r\n") client:receive("*l") end -- "Expect: 100-continue" basic support
		-- Get body from socket
		if request.headers["Content-Length"] then
			if tonumber(request.headers["Content-Length"]) > requestMaxDataSize then return nil, "body too big (>15Mo)" end -- size limitation
			request.body = client:receive(request.headers["Content-Length"])
			if request.method == "POST" then request.post = httpd.parseArgs(request.body) end -- POST args
		end
		request.get = httpd.parseArgs(require("socket.url").parse(request.path).query or "") -- Parse GET args
		httpd.log("%s > %s", httpd.peername(client), lines[1]) -- Logging
		return request
	end,
	sendResponse = function(client, code, headers, body) -- send an HTTP response to a client
		local text = "HTTP/1.1 "..code.."\r\n" -- First line
		for name, value in pairs(headers) do text = text..name..": "..value.."\r\n" end -- Add headers
		text = text.."\r\n"..body -- Add body
		httpd.log("%s < HTTP/1.1 %s", httpd.peername(client), code) -- Logging
		client:send(text)
	end,
	-- Start the server with the pages{pathMatch=function(request,captures)return{respCode,headers,body}end,pathMatch2={code,headers,body},...} and errorPages{404=sameAsPages,...}
	-- Optional table: options{debug=enable debug mode, timeout=client timeout in seconds before assuming he ran away (full sync server yeah)}
	start = function(address, port, pages, errorPages, options)
		options = options or { debug = false, timeout = 1 }
		-- Start server
		local socket = require("socket")
		local url = require("socket.url")
		local server = socket.bind(address, port)
		httpd.log("HTTP server started on %s", ("%s:%s"):format(server:getsockname()))
		local running = true
		-- Debug mode
		if options.debug then
			httpd.log("Debug mode enabled")
			server:settimeout(1) -- Enable timeout (don't block forever so we can run debug code)
			-- Warp the server object so we can rewrite its functions
			local realServer = server
			server = setmetatable({}, {__index = function(t, k) return function(_, ...) return realServer[k](realServer, ...) end end})
			-- Reload file on change
			local lfs = require("lfs")
			local lastModification = lfs.attributes(arg[0]).modification -- current last modification time
			function server:accept(...)
				if lfs.attributes(arg[0]).modification > lastModification then
					httpd.log("File changed, restarting server...\n----------------------------------------")
					running = false
				end
				return realServer:accept(...)
			end
		end
		-- Main loop
		while running do
			local client = server:accept() -- blocks indefinitly (nothing else to do anyway)
			if client then
				httpd.log("Accepted connection from client %s", httpd.peername(client))
				client:settimeout(options.timeout or 1)
				-- Handle request
				local success, err = xpcall(function()
					local req, err = httpd.getRequest(client)
					if req then
						local responded = false -- the request has been handled
						for path, page in pairs(pages) do
							local shortPath = url.parse(req.path).path -- path without GET arguments and stuff like that
							if shortPath:match("^"..path.."$") then -- strict match
								local response = type(page) == "table" and page or page(req, req.path:match("^"..path.."$"))
								if response then
									httpd.sendResponse(client, unpack(response))
									responded = true
									break
								end
							end
						end
						if not responded then
							local page = errorPages["404"] or {"404", {}, "Page not found"} -- simple default 404 page
							httpd.sendResponse(client, unpack(type(page) == "table" and page or page(request)))
						end
					else httpd.log("%s - Invalid request: %s", httpd.peername(client), err) end
				end, function(error) return error..debug.traceback("", 2) end) -- add traceback to the error message
				if not success then
					httpd.log("Internal server error: %s", err)
					pcall(function()
						local page = errorPages["500"] or {"500", {}, "Internal server error"} -- simple default 500 page
						httpd.sendResponse(client, unpack(type(page) == "table" and page or page(request)))
					end)
				end
				client:close()
			end
		end
		server:close()
		if options.debug then os.execute((arg[-1] and (arg[-1].." ") or "")..arg[0].." "..table.concat(arg, " ")) end -- Restart server
	end
}
-- Vrel --
-- Load data
local data = {} -- { ["name"] = { expire = os.time()+lifetime, burnOnRead = false, data = "Hello\nWorld" } }
local sqliteAvailable, sqlite3 = pcall(require, "lsqlite3")
if sqliteAvailable then httpd.log("Using SQlite3 storage backend") -- SQlite backend
	local db = sqlite3.open("database.sqlite3")
	db:exec("CREATE TABLE IF NOT EXISTS data (name STRING PRIMARY KEY NOT NULL, expire INTEGER NOT NULL, burnOnRead INTEGER NOT NULL, data STRING NOT NULL)")
	setmetatable(data, {
		__index = function(self, key) -- data[name]: get paste { expire = integer, burnOnRead = boolean, data = string }
			local stmt = db:prepare("SELECT expire, burnOnRead, data FROM data WHERE name = ?") stmt:bind_values(key)
			local r for row in stmt:nrows() do r = row r.burnOnRead = r.burnOnRead == 1 break end stmt:finalize()
			return r
		end,
		__newindex = function(self, key, value)
			if value ~= nil then -- data[name] = { expire = integer, burnOnRead = boolean, data = string }: add paste
				local stmt = db:prepare("INSERT INTO data VALUES (?, ?, ?, ?)") stmt:bind_values(key, value.expire, value.burnOnRead, value.data)
				stmt:step() stmt:finalize()
			else -- data[name] = nil: delete paste
				local stmt = db:prepare("DELETE FROM data WHERE name = ?") stmt:bind_values(key)
				stmt:step() stmt:finalize()
			end
		end,
		__clean = function(self, time) -- clean database
			local stmt = db:prepare("DELETE FROM data WHERE expire < ?") stmt:bind_values(time)
			stmt:step() stmt:finalize()
		end,
		__gc = function(self) db:close() end -- stop storage
	})
else httpd.log("Using in-memory storage backend") -- In-memory (table) backend
	setmetatable(data, { __clean = function(self, time) for name, d in pairs(self) do if d.expire < time then self[name] = nil end end end })
end
-- Helpers functions
local forbiddenName = { ["g"] = true, ["p"] = true }
local function generateName() -- generate a paste name
	local name = ""
	repeat
		local charType, char = math.random()
		if charType < 10/62 then char = math.random(48, 57) -- numbers (10 possibilities out of 62)
		elseif charType < 36/62 then char = math.random(65, 90) -- upper letters (26 possibilities out of 62)
		else char = math.random(97, 122) end -- lower letters (26 possibilities out of 62)
		name = name..string.char(char)
	until not (data[name] or forbiddenName[name])
	return name
end
local lastClean, cleanInterval = os.time(), 1800 -- last clean time (all time are stored in seconds) and clean interval (30min)
local maxLifetime, defaultLifetime = 7776000, 86400 -- maximum lifetime of a data (3 month) and default (1 day)
local function clean() -- clean the database each cleanInterval
	local time = os.time()
	if lastClean + cleanInterval < time then
		getmetatable(data).__clean(data, time)
		lastClean = time
	end
end
local function get(name) clean() -- get a paste (returns nil if non-existent) (returned data is expected to be safe)
	if data[name] then
		local d = data[name]
		if d.expire < os.time() then data[name] = nil return end
		if d.burnOnRead then data[name] = nil end
		return d
	end
end
local function post(paste) clean() -- add a paste, will check data and auto-fill defaults; returns name, data table
	local name = generateName()
	if paste.lifetime then paste.expire = os.time() + (tonumber(paste.lifetime) or defaultLifetime) end
	paste.expire = math.min(tonumber(paste.expire) or os.time()+defaultLifetime, os.time()+maxLifetime)
	paste.burnOnRead = paste.burnOnRead == true
	paste.data = tostring(paste.data)
	data[name] = paste
	return name, data[name]
end
local pygmentsStyle, extraStyle = "monokai", "*{color:#F8F8F2;background-color:#272822;margin:0px;}pre{color:#8D8D8A;}" -- pygments style name, extra css for highlighted blocks (also aply if no pygments)
local function highlight(code, lexer) -- Syntax highlighting; should returns the code block, style and everything included
	local source = assert(io.open("pygmentize.tmp", "w")) -- Lua can't at the same time write an read from a command, so we need to put one in a file
	source:write(code) source:close()
	local pygments = assert(io.popen("pygmentize -f html -O linenos=table,style="..pygmentsStyle.." -l "..lexer.." pygmentize.tmp", "r"))
	local out = assert(pygments:read("*a")) pygments:close()
	if #out > 0 then -- if pygments available (returned something)
		local style = assert(io.popen("pygmentize -f html -S "..pygmentsStyle, "r")) -- get style data
		out = out.."<style>"..extraStyle..assert(style:read("*a")).."</style>" style:close()
		return out
	-- no highlighter available, put in <pre><code> and escape
	else return "<style>"..extraStyle.."</style><pre><code>"..code:gsub("([\"&<>])",{["\""]="&quot;",["&"]="&amp;",["<"]="&lt;",[">"]="&gt;"}).."</code></pre>" end
end
-- Start!
httpd.start("*", 8155, { -- Pages
	["/([^/]*)"] = function(request, name)
		if forbiddenName[name] then return end
		return { "200 OK", {["Content-Type"] = "text/html"},
[[<!DOCTYPE html>
<html><head><meta charset="utf-8"/><title>vrel</title></head>
<body>]]..(#name == 0 and [[
	<style>
		* { padding: 0em; margin: 0em; color: #F8F8F2; background-color: #000000; font-size: 0.95em; font-family: mono, sans; border-style: none; }
		form * { background-color: #272822; }
		textarea[name=data] { resize: none; position: fixed; width: 100%; height: calc(100% - 2.75em); /* 2.75em = textsize + 2*margin topbar */ }
		#topbar { margin: 0.45em 0.2em; height: 1.85em; background-color: #000000; }
		#topbar #controls { padding: 0.5em; }
		#topbar input { height: 2em; text-align: center; background-color: #383832; }
		#topbar input[name=lifetime] { width: 5em; }
		#topbar input[name=burnOnRead] { vertical-align: middle; }
		#topbar input[type=submit] { cursor: pointer; width: 10em; }
		#topbar #vrel { font-size: 1.5em; float: right; }
	</style>
	<form method="POST" action="/p">
		<div id="topbar"><span id="controls">expires in <input name="lifetime" type="number" min="1" max="]]..math.floor(maxLifetime/3600)..[[" value="]]..math.floor(defaultLifetime/3600)..
		[["/> hours (<input name="burnOnRead" type="checkbox"/>burn on read) <input type="submit" value="post"/></span><a id="vrel" href="/">vrel</a></div>
		<textarea name="data" required=true></textarea>
	</form>]] or highlight((get(name) or {data="paste not found"}).data, "lua"))..[[
</body></html>]]
		}
	end,
	["/g/(.+)"] = function(request, name) local d = get(name) return d and { "200 OK", {["Content-Type"] = "text"}, d.data } or nil end,
	["/p"] = function(request)
		if request.method == "POST" and request.post.data then
			local name, data = post({ lifetime = (tonumber(request.post.lifetime) or defaultLifetime/3600)*3600, burnOnRead = request.post.burnOnRead == "on", data = request.post.data })
			return { "200 OK", {["Content-Type"] = "text/json"}, "{\"name\":\""..name.."\",\"lifetime\":"..data.expire-os.time()..",\"burnOnRead\":"..tostring(data.burnOnRead).."}\n" }
		end
	end
}, { -- Error pages
	["404"] = { "404", {["Content-Type"] = "text/json"}, "{\"error\":\"page not found\"}\n" }, ["500"] = { "500", {["Content-Type"] = "text/json"}, "{\"error\":\"internal server error\"}\n" }
}, { timeout = 1, debug = true })