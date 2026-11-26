--[[ Downloads one URL to a file with KOReader's own HTTP/HTTPS stack (the Kindle's busybox
wget has no TLS). Run from the koreader directory, usually in the background:
    ./luajit plugins/khomestuck.koplugin/fetch.lua <url> <out>
Writes <out>.part while downloading (its size is the progress) and renames it to <out> when
done. Follows redirects itself, since GitHub release links redirect to another host. ]]
require("setupkoenv")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
-- LuaSocket waits 60 s per stalled read by default; the list fetch blocks KOReader's screen
http.TIMEOUT, https.TIMEOUT = 15, 15

local url, out = arg[1], arg[2]
local part = out .. ".part"
for _ = 1, 5 do
    local f = assert(io.open(part, "wb"))
    local mod = url:match("^https:") and https or http
    local _, code, headers = mod.request{ url = url, sink = ltn12.sink.file(f), redirect = false }
    if code == 301 or code == 302 or code == 303 or code == 307 or code == 308 then
        url = headers.location
    elseif code == 200 then
        os.rename(part, out)
        os.exit(0)
    else
        os.remove(part)
        io.stderr:write("fetch: ", tostring(code), " for ", url, "\n")
        os.exit(1)
    end
end
os.remove(part)
io.stderr:write("fetch: too many redirects\n")
os.exit(1)
