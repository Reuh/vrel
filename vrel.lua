#!/bin/lua
--- vrel v0.1.6: online paste service, in 256 lines of Lua (max line lenght = 256).
-- This module requires LuaSocket 2.0.2, and debug mode requires LuaFileSystem 1.6.3. Install pygmentize for the optional syntax highlighting. If you want persistance for paste storage, install lsqlite3. vrel should work with Lua 5.1 to 5.3.
math.randomseed(os.time())
local hasConfigFile, config = pcall(dofile, "config.lua") if not hasConfigFile then config = {} end
-- Basic HTTP 1.0 server --
local httpd = nil
httpd = {
	log = function(str, ...) print("["..os.date().."] "..str:format(...)) end, -- log a message (str:format(...))
	peername = function(client) return ("%s:%s"):format(client:getpeername()) end, -- returns a nice display name for the client (address:port)
	unescape = function(txt) return require("socket.url").unescape(txt:gsub("+", " ")) end, -- unescape URL-encoded stuff
	parseUrlEncoded = function(args) -- parse GET or POST arguments and returns the corresponding table {argName=argValue,...} (strings)
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
			version = "HTTP/1.0", -- HTTP version string
			headers = {}, -- headers table: {headerName=headerValue,...} (strings)
			body = "", -- request body
			post = { mimetype = {} }, -- POST args {argName=argValue,...,mimetype={argName=argMimeType}} (strings)
			get = {} -- GET args {argName=argValue,...} (strings)
		}
		local lines = {} -- Headers
		repeat local message = client:receive("*l") table.insert(lines, message) until not message or #message == 0 -- Get headers data from socket
		request.method, request.path, request.version = lines[1]:match("(%S*)%s(%S*)%s(%S*)") -- Parse first line (method, path and HTTP version)
		if not request.method then return nil, "malformed request" end
		for i=2, #lines, 1 do -- Parse headers
			local name, value = lines[i]:match("^(.-)%:%s(.*)$")
			if name and value then request.headers[name] = value
			elseif #lines[i] == 0 then break
			else return nil, "malformed headers" end
		end
		if request.headers["Content-Length"] then -- Get body from socket
			if tonumber(request.headers["Content-Length"]) > (httpd.options.requestMaxDataSize or 5242880) then return nil, ("body too big (>%sB)"):format(httpd.options.requestMaxDataSize or 5242880) end -- size limitation
			for i=0, request.headers["Content-Length"], (httpd.options.maxChunkSize or 1024) do
				request.body = request.body .. client:receive(math.min(httpd.options.maxChunkSize or 1024, request.headers["Content-Length"]-i))
				coroutine.yield()
			end
			if request.method == "POST" then -- POST args
				if request.headers["Content-Type"]:match("multipart%/form%-data") then
					local boundary = request.headers["Content-Type"]:match("multipart%/form%-data%; boundary%=([^;]+)"):gsub("%p", "%%%1")
					for part in request.body:match("%-%-"..boundary.."(.*)"):gmatch("\r\n(.-)\r\n%-%-"..boundary) do
						local headers, content = part:match("(.-\r\n)\r\n(.*)")
						local name = headers:match("Content%-Disposition:%sform%-data; name%=\"([^\";\r]-)\"")
						request.post[name], request.post.mimetype[name] = content, headers:match("Content%-Type:%s(.-)\r\n")
					end
				else request.post = httpd.parseUrlEncoded(request.body) end -- application/x-www-form-urlencoded
			end
		end
		request.get = httpd.parseUrlEncoded(require("socket.url").parse(request.path).query or "") -- Parse GET args
		httpd.log("%s > %s", httpd.peername(client), lines[1]) -- Logging
		return request
	end,
	sendResponse = function(client, code, headers, body) -- send an HTTP response to a client
		local text = "HTTP/1.0 "..code.."\r\n" -- First line
		for name, value in pairs(headers) do text = text..name..": "..value.."\r\n" end -- Add headers
		client:send(text.."\r\n"..body.."\r\n") -- Add body & send
		httpd.log("%s < HTTP/1.0 %s", httpd.peername(client), code) -- Logging
	end,
	-- Start the server with the pages{pathMatch=function(request,captures)return{[cache=cacheDuration,]respCode,headers,body}end,pathMatch2={code,headers,body},...} and errorPages{404=sameAsPages,...}
	-- Optional table: options{debug=enable debug mode, timeout=client timeout in seconds before assuming he ran away before sending a full chunk, cacheCleanInterval = remove expired cache entries each interval of time (seconds),
	--                         requestMaxDataSize = max post/paste data size (bytes) (5MiB), maxChunkSize = max chunk size to receive at once from a client (bytes) (1KiB)}
	start = function(address, port, pages, errorPages, options)
		httpd.options = options or { debug = false, timeout = 1, cacheCleanInterval = 3600, requestMaxDataSize = 5242880, maxChunkSize = 1024 }
		local socket, url = require("socket"), require("socket.url")
		local server, running = socket.bind(address, port), true -- start server
		local cache, nextCacheClean, requests = {}, os.time() + (httpd.options.cacheCleanInterval or 3600), {}
		httpd.log("HTTP server started on %s", ("%s:%s"):format(server:getsockname()))
		if httpd.options.debug then -- Debug mode
			httpd.log("Debug mode enabled")
			server:settimeout(1) -- Enable timeout (don't block forever so we can run debug code)
			local realServer = server
			server = setmetatable({}, {__index = function(_, k) return function(_, ...) return realServer[k](realServer, ...) end end}) -- Warp the server object so we can rewrite its functions
			local lfs = require("lfs") -- Reload file on change
			local lastModification = lfs.attributes(arg[0]).modification -- current last modification time
			function server:accept(...)
				if lfs.attributes(arg[0]).modification > lastModification then
					httpd.log("File changed, restarting server...\n----------------------------------------")
					running = false
				end
				return realServer:accept(...)
			end
		end
		while running do -- Main loop
			local client = server:accept() -- blocks indefinitly if nothing else to do
			if client then
				server:settimeout(0)
				table.insert(requests, { client = client, coroutine = coroutine.create(function() -- Add request handler to queue
					httpd.log("Accepted connection from client %s", httpd.peername(client))
					client:settimeout(httpd.options.timeout or 1)
					local req, err = httpd.getRequest(client)
					if req then
						if cache[req.path] and cache[req.path].expire >= os.time() then httpd.sendResponse(client, unpack(cache[req.path].response)) return end
						local responded = false -- the request has been handled
						local shortPath = url.parse(req.path).path -- path without GET arguments and stuff like that
						for path, page in pairs(pages) do
							if shortPath:match("^"..path.."$") then -- strict match
								local response = type(page) == "table" and page or page(req, req.path:match("^"..path.."$"))
								if response then
									if response.cache then -- put in cache
										cache[req.path] = { expire = os.time() + response.cache, response = response }
										response[2]["Expires"] = os.date("!%a, %d %b %Y %H:%M:%S GMT", cache[req.path].expire)
									end
									httpd.sendResponse(client, unpack(response))
									responded = true break
								end
							end
						end
						if not responded then httpd.sendResponse(client, unpack(type(errorPages["404"]) == "function" and errorPages["404"](req) or errorPages["404"] or {"404", {}, "Page not found"})) end
					else httpd.log("%s - Invalid request: %s", httpd.peername(client), err) end
					client:close()
				end)})
			end
			for i=#requests, 1, -1 do -- Process requests
				local success, err = coroutine.resume(requests[i].coroutine)
				if not success then
					httpd.log("Internal server error: %s", err)
					pcall(function() httpd.sendResponse(requests[i].client, unpack(type(errorPages["500"]) == "function" and errorPages["500"]() or errorPages["500"] or {"500", {}, "Internal server error"})) end)
					requests[i].client:close()
				end
				if coroutine.status(requests[i].coroutine) == "dead" then table.remove(requests, i) end
			end
			if #requests == 0 then server:settimeout() end
			local time = os.time()
			if nextCacheClean < time then -- clean cache
				for path, req in pairs(cache) do if req.expire < time then cache[path] = nil end end
				nextCacheClean = time + (httpd.options.cacheCleanInterval or 3600)
			end
		end
		server:close()
		if httpd.options.debug then os.execute((arg[-1] and (arg[-1].." ") or "")..arg[0].." "..table.concat(arg, " ")) end -- Restart server
	end
}
-- Vrel --
-- Load data
local data = {} -- { ["name"] = { expire = os.time()+lifetime, burnOnRead = false, senderId = "someuniqueidentifier", syntax = "lua", data = "Hello\nWorld" } }
local sqliteAvailable, sqlite3 = pcall(require, "lsqlite3")
if sqliteAvailable then httpd.log("Using SQlite3 storage backend") -- SQlite backend
	local db = sqlite3.open("database.sqlite3")
	db:exec("CREATE TABLE IF NOT EXISTS data (name TEXT PRIMARY KEY NOT NULL UNIQUE, expire INTEGER NOT NULL, burnOnRead INTEGER NOT NULL DEFAULT 0, senderId TEXT NOT NULL, syntax TEXT NOT NULL DEFAULT 'text', "..
		"mimetype TEXT NOT NULL DEFAULT 'text/plain; charset=utf-8', data BLOB NOT NULL)")
	setmetatable(data, {
		__index = function(self, key) -- data[name]: get paste { expire = integer, burnOnRead = boolean, data = string }
			local stmt = db:prepare("SELECT expire, burnOnRead, senderId, syntax, mimetype, data FROM data WHERE name = ?") stmt:bind_values(key)
			local r for row in stmt:nrows() do r = row r.burnOnRead = r.burnOnRead == 1 break end stmt:finalize()
			return r
		end,
		__newindex = function(self, key, value)
			if value ~= nil then -- data[name] = { expire = integer, burnOnRead = boolean, syntax = string, data = string }: add paste
				local stmt = db:prepare("INSERT INTO data VALUES (?, ?, ?, ?, ?, ?, ?)") stmt:bind_values(key, value.expire, value.burnOnRead, value.senderId, value.syntax, value.mimetype, value.data) stmt:step() stmt:finalize()
			else local stmt = db:prepare("DELETE FROM data WHERE name = ?") stmt:bind_values(key) stmt:step() stmt:finalize() end -- data[name] = nil: delete paste
		end,
		__clean = function(self, time) -- clean database
			local stmt = db:prepare("DELETE FROM data WHERE expire < ?") stmt:bind_values(time) stmt:step() stmt:finalize()
		end,
		__gc = function(self) db:close() end -- stop storage
	})
else httpd.log("Using in-memory storage backend") -- In-memory (table) backend
	setmetatable(data, { __clean = function(self, time) for name, d in pairs(self) do if d.expire < time then self[name] = nil end end end })
end
-- Helpers functions
local forbiddenName = { ["g"] = true, ["t"] = true, ["p"] = true }
local function generateName(size) -- generate a paste name. If size ~= nil, will generate a random ID of this lenght.
	local name = ""
	repeat
		local charType, char = math.random()
		if charType < 10/62 then char = math.random(48, 57) -- numbers (10 possibilities out of 62)
		elseif charType < 36/62 then char = math.random(65, 90) -- upper letters (26 possibilities out of 62)
		else char = math.random(97, 122) end -- lower letters (26 possibilities out of 62)
		name = name..string.char(char)
	until (not size and not (data[name] or forbiddenName[name])) or (#name >= (size or math.huge))
	return name
end
local function getClientId(request)	return request.headers["X-Forwarded-For"] or request.client:getpeername() end -- returns some identifier for the client who sent the request
local lastClean, cleanInterval = os.time(), config.cleanInterval or 1800 -- last clean time (all time are stored in seconds) and clean interval (30min)
local maxLifetime, defaultLifetime = config.maxLifetime or 15552000, config.defaultLifetime or 86400 -- maximum lifetime of a paste (6 month) and default (1 day)
local function clean() -- clean the database each cleanInterval
	local time = os.time()
	if lastClean + cleanInterval < time then getmetatable(data).__clean(data, time) lastClean = time end
end
local function get(name, request) clean() -- get a paste (returns nil if non-existent) (returned data is expected to be safe)
	if data[name] then
		local d = data[name]
		if d.expire < os.time() then data[name] = nil return end
		if getClientId(request) ~= d.senderId and d.burnOnRead then data[name] = nil end -- burn on read (except if retrieved by original poster)
		return d
	end
end
local function post(paste, request) clean() -- add a paste, will check data and auto-fill defaults; returns name, paste data table
	local name = generateName()
	if paste.lifetime then paste.expire = os.time() + (tonumber(paste.lifetime) or defaultLifetime) end
	paste.expire = math.min(tonumber(paste.expire) or os.time()+defaultLifetime, os.time()+maxLifetime)
	paste.burnOnRead, paste.senderId = paste.burnOnRead == true, paste.senderId or getClientId(request) or "unknown"
	paste.syntax, paste.mimetype = (paste.syntax or (paste.mimetype or ""):match("text%/x?%-?(%a+)") or "text"):lower():match("[a-z]*"), paste.mimetype or "text/plain; charset=utf-8"
	paste.data = tostring(paste.data)
	data[name] = paste
	return name, data[name]
end
local pygmentsStyle, extraStyle = config.pygmentsStyle or "monokai", config.extraStyle or "*{color:#F8F8F2;background-color:#272822;margin:0px;}pre{color:#8D8D8A;}" -- pygments style name, extra css for highlighted blocks (also aply if no pygments)
local function highlight(paste, forceLexer) -- Syntax highlighting; should returns the style CSS code and code block HTML
	local source = assert(io.open("pygmentize.tmp", "w")) -- Lua can't at the same time write an read from a command, so we need to put one in a file
	source:write(paste.data) source:close()
	local pygments = assert(io.popen("pygmentize -P encoding=utf-8 -f html -O linenos=table,style="..pygmentsStyle.." -l "..(forceLexer or paste.syntax or "text").." pygmentize.tmp", "r"))
	local out = assert(pygments:read("*a")) pygments:close()
	if #out > 0 then -- if pygments available and available lexer (returned something)
		local style = assert(io.popen("pygmentize -f html -S "..pygmentsStyle, "r")) -- get style data
		local outstyle = extraStyle..assert(style:read("*a")) style:close()
		return outstyle, out
	else return extraStyle, "<pre><code>"..paste.data:gsub("([\"&<>])",{["\""]="&quot;",["&"]="&amp;",["<"]="&lt;",[">"]="&gt;"}).."</code></pre>" end -- no highlighter available, put in <pre><code> and escape
end
-- Start!
httpd.start(config.address or "*", config.port or 8155, { -- Pages
	["/([^/]*)"] = function(request, name)
		if forbiddenName[name] then return end
		if #name == 0 then return { cache = config.cacheDuration or 3600, "200 OK", {["Content-Type"] = "text/html"}, [[<!DOCTYPE html><html><head><meta charset=utf-8><title>vrel</title><style>
	* { padding: 0; margin: 0; color: #F8F8F2; background-color: #000000; font-size: 95%; font-family: mono, sans; border-style: none; }
	form * { background-color: #272822; }
	textarea[name=data] { resize: none; position: absolute; width: 100%; height: calc(100% - 2.7rem); /* 2.7rem = textsize + 2*margin topbar */ }
	#topbar { margin: 0.35rem 0.15rem; background-color: #000000; }
	#topbar #controls { padding: 0.4rem; }
	#topbar input { height: 1.7rem; text-align: center; background-color: #383832; }
	#topbar input[name=lifetime] { width: 3.5rem; } #topbar input[name=burnOnRead] { vertical-align: middle; }
	#topbar input[name=syntax] { width: 4.7rem; }
	#topbar input[type=submit] { cursor: pointer; width: 8rem; }
	#topbar #vrel { font-size: 1.4rem; float: right; }
</style><meta name="viewport" content="width=device-width,initial-scale=1"></head><body><form method=POST action=/p enctype=multipart/form-data><input name=web type=hidden value=on>
	<div id=topbar><span id=controls>expires in <input name=lifetime type=number min=1 max=]]..math.floor(maxLifetime/3600)..[[ value=]]..math.floor(defaultLifetime/3600)..[[> hours (<input name=burnOnRead type=checkbox>burn on read)
	<input name=syntax type=text placeholder=syntax> (or send a file <input name=file type=file>) <input type=submit value=post></span><a id=vrel href="]]..(config.titleLink or "/")..[[" title=0.1.6>vrel</a></div>
	<textarea name=data autofocus placeholder="paste your text here"></textarea>
</form></body></html>]] }
		else local paste = get(name:match("^[^.]+"), request) or { data = "paste not found", syntax = "text", expire = os.time() }
			return { cache = not paste.burnOnRead and math.min(paste.expire - os.time(), config.cacheDuration or 3600), "200 OK", {["Content-Type"] = "text/html"},
			         ([[<!DOCTYPE html><html><head><meta charset=utf-8><title>%s - vrel</title><style>%s</style></head><body>%s</body></html>]]):format(name, highlight(paste, name:lower():match("%.([a-z]+)$"))) }
		end
	end,
	["/g/(.+)"] = function(request, name) local d = get(name, request) return d and { cache = math.min(d.expire - os.time(), config.cacheDuration or 3600), "200 OK", {["Content-Type"] = d.mimetype}, d.data } or nil end,
	["/t/(.+)"] = function(request, name) local d = get(name, request) return d and { cache = math.min(d.expire - os.time(), config.cacheDuration or 3600), "200 OK", {["Content-Type"] = "text/plain; charset=utf-8"}, d.data } or nil end,
	["/p"] = function(request)
		if request.post.web and #(request.post.file or "") > #(request.post.data or "") then request.post.data, request.post.mimetype.data = request.post.file, request.post.mimetype.file end
		if request.method == "POST" and request.post.data then
			local name, paste = post({ lifetime = (tonumber(request.post.lifetime) or defaultLifetime)*(request.post.web and 3600 or 1), burnOnRead = request.post.burnOnRead == "on",
				syntax = not (request.post.web and request.post.syntax == "") and request.post.syntax or nil, mimetype = request.post.mimetype.data, data = request.post.data }, request)
			return request.post.web and { "303 See Other", {["Location"] = (paste.mimetype:match("text") and "/" or "/g/")..name}, "" } or
				{ "200 OK", {["Content-Type"] = "text/json; charset=utf-8"}, ([[{"name":%q,"lifetime":%q,"burnOnRead":%s,"syntax":%q,"mimetype":%q}]]):format(name, paste.expire-os.time(), tostring(paste.burnOnRead), paste.syntax, paste.mimetype) }
		end
	end
}, { ["404"] = { "404", {["Content-Type"] = "text/json; charset=utf-8"}, [[{"error":"page not found"}]] }, ["500"] = { "500", {["Content-Type"] = "text/json; charset=utf-8"}, [[{"error":"internal server error"}]] } -- Error pages
}, { timeout = config.timeout or 1, debug = config.debug or false, cacheCleanInterval = config.cacheCleanInterval or 3600 })
