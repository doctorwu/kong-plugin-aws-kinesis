-- load the base plugin object and create a subclass
local plugin = require("kong.plugins.base_plugin"):extend()
local Multipart = require "multipart"
local cjson = require "cjson.safe"
local utils = require "kong.tools.utils"
local jp = require "jsonpath"
local aws_v4 = require "kong.plugins.aws-lambda.v4"
local responses = require "kong.tools.responses"
local http = require "resty.http"

local CONTENT_TYPE = "content-type"

-- constructor
function plugin:new()
  plugin.super.new(self, "aws-kinesis")  
end

local function retrieve_parameters()
  ngx.req.read_body()
  local body_parameters, err
  local content_type = ngx.req.get_headers()[CONTENT_TYPE]
  if content_type and string.find(content_type:lower(), "multipart/form-data", nil, true) then
    body_parameters = Multipart(ngx.req.get_body_data(), content_type):get_all()
  elseif content_type and string.find(content_type:lower(), "application/json", nil, true) then
    body_parameters, err = cjson.decode(ngx.req.get_body_data())
    if err then
      body_parameters = {}
    end
  else
    body_parameters = ngx.req.get_post_args()
  end

  return utils.table_merge(ngx.req.get_uri_args(), body_parameters)
end

---[[ runs in the 'access_by_lua_block'
function plugin:access(config)
  plugin.super.access(self)

  local params = retrieve_parameters()
  
  -- set partition key
  local partition_key
  if config.partition_key_path then
    partition_key = jp.value(params, config.partition_key_path)
  end
  if not partition_key then
    partition_key = ngx.md5(cjson.encode(params))
  end

  -- set client ip
  local client_ip = ngx.var.remote_addr
  if ngx.req.get_headers()['x-forwarded-for'] then
    client_ip = string.match(ngx.req.get_headers()['x-forwarded-for'], "[^,%s]+")
  end

  local body = {
    StreamName = config.stream_name,
    Data = ngx.encode_base64(cjson.encode({ip = client_ip, payload = params})),
    PartitionKey = partition_key
  }
  local bodyJson = cjson.encode(body)

  local opts = {
    region = config.aws_region,
    service = "kinesis",
    method = "POST",
    headers = {
      ["X-Amz-Target"] = "Kinesis_20131202.PutRecord",
      ["Content-Type"] = "application/x-amz-json-1.1",
      ["Content-Length"] = tostring(#bodyJson)
    },
    body = bodyJson,
    path = "/",
    access_key = config.aws_key,
    secret_key = config.aws_secret,
  }

  local request, err = aws_v4(opts)
  if err then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  -- Trigger request
  local host = string.format("kinesis.%s.amazonaws.com", config.aws_region)
  local client = http.new()
  client:connect(host, 443)
  client:set_timeout(config.timeout)
  local ok, err = client:ssl_handshake()
  if not ok then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  local res, err = client:request {
    method = "POST",
    path = request.url,
    body = request.body,
    headers = request.headers
  }

  if not res then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  local resp_body = res:read_body()
  local resp_headers = res.headers

  local ok, err = client:set_keepalive(config.keepalive)
  if not ok then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  ngx.status = res.status

  -- Send response to client
  for k, v in pairs(resp_headers) do
    ngx.header[k] = v
  end

  ngx.say(resp_body)

  return ngx.exit(res.status)
end --]]

-- set the plugin priority, which determines plugin execution order
plugin.PRIORITY = 1000

-- return our plugin object
return plugin
