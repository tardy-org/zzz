
// ws example (wss - with cert, with https)

const std = @import("std");

const zzz = @import("zzz");

//const websocket = @import("zzz/websocket/websocket.zig");
const websocket = zzz.websocket;

const Socket = zzz.tardy.Socket;


//const PORT = 3010;
const PORT = 443;
const HOST = "0.0.0.0";


const STACK_SIZE = if (@import("builtin").mode == .Debug)
  1 * 1024 * 1024 // DEBUG = 1mb
else
  32 * 1024; // RELEASE = 32kb


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
  
  //const res = try websocket.upgrade(&ctx.socket, ctx.runtime, ctx.allocator, key, ext, header_buf.writer());
  const res = try websocket.upgrade(&ctx.socket, ctx.runtime, key, ext, header_buf.writer());
  
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
    //@compileLog("STACK_SIZE = ", STACK_SIZE);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    const socket = try Socket.init(.{ .tcp = .{ .host = HOST, .port = PORT } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024); // max conn count that are waiting in accept queue
    
    const home_route = zzz.HTTP.Route.init("/").get({}, on_request);
    const ws_route = zzz.HTTP.Route.init("/ws").get({}, on_ws_endpoint);
    const layers = &[_]zzz.HTTP.Layer{
      home_route.layer(),
      ws_route.layer(),
    };
    
    const router = try zzz.Router.init(allocator, layers, .{ .not_found = on_request });
    // no defer router - lifetime per server work
    
    var bearssl = zzz.secsock.BearSSL.init(allocator);
    defer bearssl.deinit();
    
    const cert = try std.fs.cwd().readFileAlloc(allocator, FULLCHAIN_CERT, 1024 * 10);
    defer allocator.free(cert);
    const key = try std.fs.cwd().readFileAlloc(allocator, PRIVKEY_CERT, 1024 * 10);
    defer allocator.free(key);
    
    try bearssl.add_cert_chain("CERTIFICATE", cert, "PRIVATE KEY", key);
    const secure_socket = try bearssl.to_secure_socket(socket, .server);
    defer secure_socket.deinit();
    
    var tardy = try zzz.tardy.Tardy(.auto).init(allocator, .{});
    defer tardy.deinit();
    
    var server = zzz.Server.init(.{ .stack_size = STACK_SIZE });
    
    const Entry_Params = struct {
      //config: zzz.ServerConfig,
      server: *zzz.Server,
      router: *const zzz.Router,
      socket: zzz.secsock.SecureSocket,
    };
    
    try tardy.entry(
      //Entry_Params{ .config = .{ .stack_size = STACK_SIZE }, .router = &router, .socket = secure_socket },
      Entry_Params{ .server = &server, .router = &router, .socket = secure_socket },
      struct {
        fn entry(rt: *zzz.tardy.Runtime, p: Entry_Params) !void {
          //var server = zzz.Server.init(p.config);
          //try server.serve(rt, p.router, .{ .secure = p.socket });
          try p.server.serve(rt, p.router, .{ .secure = p.socket });
        } // end fn entry
    }.entry);
}

