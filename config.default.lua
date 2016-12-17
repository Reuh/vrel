--- Configuration files for vrel.
-- No line count limitation ; vrel will work fine without this, so I guess it's not cheating.
-- In fact, this file will be read by vrel only if named config.lua (and not config.default.lua).
-- If you want to live the full experience, you can easliy find where theses variables are used in vrel.lua and change the default value here
-- instead of using a config.lua file.
-- Also, the comments describing each variable in this file are here solely for practicality purposes ; the comments and code in vrel.lua should
-- be enough to descibe or imply their utility.

return {
	-- Server address to bind
	address = "*",
	-- TCP port to bind
	port = 8155,
	-- Maximal lifetime of a paste
	maxLifetime = 15552000, -- 6 months
	-- Default lifetime of a paste in the web interface
	defaultLifetime = 86400, -- 1 day
	-- Maximal size of a request/paste
	requestMaxDataSize = 15728640, -- 15MB
	-- Pygments style name
	pygmentsStyle = "monokai",
	-- Extra CSS applied to syntax-highlighted blocks (with and without Pygments)
	extraStyle = "*{color:#F8F8F2;background-color:#272822;margin:0px;}pre{color:#8D8D8A;}",
	-- Request timeout
	timeout = 1, -- 1 second
	-- Debug mode
	debug = false,
	-- Time interval to remove expired webserver cache entries (seconds)
	cacheCleanInterval = 3600 -- 1 hour
}
