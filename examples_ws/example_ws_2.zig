
// ws example (wss - with cert, with https)

const std = @import("std");

const zzz = @import("zzz");

//const websocket = @import("zzz/websocket/websocket.zig");
const websocket = zzz.websocket;

const Socket = zzz.tardy.Socket;


//const PORT = 3010;
const PORT = 443;
const HOST = "0.0.0.0";

//const STACK_SIZE = 10 * 1024 * 1024; // DEBUG
const STACK_SIZE = 64 * 1024; // RELEASE

const FULLCHAIN_CERT = "examples_ws/cert/fullchain.pem";
const PRIVKEY_CERT = "examples_ws/cert/privkey.pem";


const ServerContext = struct {
  socket: Socket,
  cert_pem: []const u8,
  key_pem: []const u8,
};


// WebSocket handlers
fn on_ws_connect(conn: websocket.Conn) !void{
  try conn.send("Hello from zzz WebSocket!");
  std.log.info("WebSocket connected", .{});
}


fn on_ws_close(conn: websocket.Conn, code: u16, reason: []const u8) !void{
  _ = conn;
  std.log.info("WS closed: code={d}, reason={s}", .{ code, reason });
}


fn on_ws_message(conn: websocket.Conn, data: []const u8) !void{
  std.log.info("WS Payload received: '{s}' (len: {d})", .{data, data.len});
  try conn.send("Hello from Server!");
  std.log.info("WS <- {s}", .{data});
}


fn on_ws_disconnect(conn: websocket.Conn) !void{
  _ = conn;
  std.log.info("WebSocket disconnected", .{});
}


// HTTP fallback
fn on_request(ctx: *const zzz.Context, _: void) !zzz.HTTP.Respond {
    const res = ctx.response;
    res.status = .OK;
    res.mime = zzz.HTTP.Mime.HTML;
    res.body =
      \\<html>
      \\<head><title>zzz + WebSocket</title></head>
      \\<body>
      \\<h1>WebSocket Test</h1>
      \\<script>
      \\const ws = new WebSocket("wss://test1.ls:443/ws"); // todo change for production subdomain
      \\ws.onmessage = (e) => console.log("ws <- ", e.data);
      \\ws.onopen = () => ws.send("Hello from browser!");
      \\ws.onclose = (e) => console.log("ws closed", e);
      \\</script>
      \\</body>
      \\</html>
    ;
    return .standard;
}


// Upgrade handler
fn on_upgrade(req: *const zzz.Request, proto: []const u8) !bool {
    if (!std.mem.eql(u8, proto, "websocket")) return false;
    
    const key = req.headers.get("Sec-WebSocket-Key") orelse return false;
    const ext = req.headers.get("Sec-WebSocket-Extensions");
    
    var header_buf = std.ArrayList(u8).init(std.heap.page_allocator);
    defer header_buf.deinit();
    
    //const res = try websocket.upgrade(req.socket, req.runtime, std.heap.page_allocator, key, ext, header_buf.writer() );
    const res = try websocket.upgrade(req.socket, req.runtime, req.runtime.allocator, key, ext, header_buf.writer() );
    
    _ = try req.socket.send_all(req.runtime, header_buf.items);
    
    const ws_handler = websocket.Handler{
      .on_connect = on_ws_connect,
      .on_message = on_ws_message,
      .on_close = on_ws_close,
      .on_disconnect = on_ws_disconnect,
    };
    
    if (ws_handler.on_connect) |f| try f(res.conn);
    try req.runtime.spawn(.{ res.conn, ws_handler, std.heap.page_allocator }, websocket.runLoop, STACK_SIZE);
    //try req.runtime.spawn(.{ res.conn, ws_handler, req.runtime.allocator }, websocket.runLoop, STACK_SIZE);
    return true;
}


fn on_ws_endpoint(ctx: *const zzz.Context, _: void) !zzz.HTTP.Respond {
  const req = ctx.request;
  
  const upgrade = req.headers.get("Upgrade");
  if (upgrade == null or !std.mem.eql(u8, upgrade.?, "websocket")) {
    ctx.response.status = .@"Bad Request";
    ctx.response.body = "Expected WebSocket Upgrade";
    return .standard;
  }
  
  const key = req.headers.get("Sec-WebSocket-Key") orelse {
    ctx.response.status = .@"Bad Request";
    return .standard;
  };
  const ext = req.headers.get("Sec-WebSocket-Extensions");
  
  var header_buf = std.ArrayList(u8).init(ctx.allocator);
  defer header_buf.deinit();
  
  const res = try websocket.upgrade(&ctx.socket, ctx.runtime, ctx.allocator, key, ext, header_buf.writer());
  
  _ = try ctx.socket.send_all(ctx.runtime, header_buf.items);
  
  const ws_handler = websocket.Handler{
    .on_connect = on_ws_connect,
    .on_message = on_ws_message,
    .on_close = on_ws_close,
    .on_disconnect = on_ws_disconnect,
  };
  
  if (ws_handler.on_connect) |f| try f(res.conn);
  
  std.log.info("Starting WebSocket Loop...", .{});
  
  //websocket.runLoop(res.conn, ws_handler, ctx.runtime.allocator) catch |err| { // sync loop
  websocket.runLoop(res.conn, ws_handler, std.heap.page_allocator) catch |err| { // sync loop
    std.log.err("WebSocket RunLoop Error: {s}", .{@errorName(err)});
    
    if (err == error.Closed) {
      std.log.info("Socket closed by browser", .{});
    }
  
  };
  
  std.log.info("WebSocket Loop finished", .{});
  return .close;
}


pub fn main() !void{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    const socket = try Socket.init(.{ .tcp = .{ .host = HOST, .port = PORT } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024); // max conn count that are waiting in accept queue
    
    const cert = try std.fs.cwd().readFileAlloc(allocator, FULLCHAIN_CERT, 1024 * 10);
    defer allocator.free(cert);
    const key = try std.fs.cwd().readFileAlloc(allocator, PRIVKEY_CERT, 1024 * 10);
    defer allocator.free(key);
    
    const ctx = ServerContext{
      .socket = socket,
      .cert_pem = cert,
      .key_pem = key,
    };
    
    const TardyType = zzz.tardy.Tardy(.auto);
    var tardy = try TardyType.init(allocator, .{});
    //var tardy = try TardyType.init(allocator, .{ .threading = .single });
    defer tardy.deinit();
    
    try tardy.entry(&ctx, struct {
        fn entry(rt: *zzz.tardy.Runtime, s_ctx: *const ServerContext) !void {
            const bearssl = try rt.allocator.create(zzz.secsock.BearSSL);
            bearssl.* = zzz.secsock.BearSSL.init(rt.allocator);
            //defer bearssl.deinit();
            
            try bearssl.add_cert_chain("CERTIFICATE", s_ctx.cert_pem, "PRIVATE KEY", s_ctx.key_pem);
            const secure_socket = try bearssl.to_secure_socket(s_ctx.socket, .server);
            //defer secure_socket.deinit();
            
            const config = zzz.ServerConfig{
                .stack_size = STACK_SIZE,
            };
            
            const home_route = zzz.HTTP.Route.init("/").get({}, on_request);
            const ws_route = zzz.HTTP.Route.init("/ws").get({}, on_ws_endpoint);
            const layers = &[_]zzz.HTTP.Layer{
              home_route.layer(),
              ws_route.layer(),
            };
            
            const router = try rt.allocator.create(zzz.Router);
            router.* = try zzz.Router.init(rt.allocator, layers, .{
              .not_found = on_request,
            });
            // no defer router - lifetime per server work
            
            const provisions = try rt.allocator.create(zzz.tardy.Pool(zzz.Provision)); // use heap instead of stack
            provisions.* = try zzz.tardy.Pool(zzz.Provision).init(rt.allocator, 1024, .static); // 1024 = pool size
            
            const byte_count = provisions.items.len * @sizeOf(zzz.Provision); // set zeros -- initialized = false
            @memset(@as([*]u8, @ptrCast(provisions.items.ptr))[0..byte_count], 0);
            
            const connection_count = try rt.allocator.create(usize); // use heap instead stack
            connection_count.* = 0;
            
            const accept_queued = try rt.allocator.create(bool);
            accept_queued.* = false;
            
            try rt.spawn(
              .{ rt, config, router, secure_socket, provisions, connection_count, accept_queued },
              zzz.Server.main_frame,
              config.stack_size
            );
        
        } // end fn entry
    }.entry);
}

