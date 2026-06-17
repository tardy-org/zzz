
// ws with Pub/Sub example

const std = @import("std");

const zzz = @import("zzz");

//const websocket = @import("zzz/websocket/websocket.zig");
const websocket = zzz.websocket;
const PubSub = zzz.PubSub;
const handle_upgrade = zzz.handle_upgrade;
const WsSession = zzz.WsSession;

const Socket = zzz.tardy.Socket;
const Timer = zzz.tardy.Timer;


const PORT = 3010;
//const PORT = 443;
const HOST = "0.0.0.0";


const STACK_SIZE = if (@import("builtin").mode == .Debug)
  1 * 1024 * 1024 // DEBUG = 1mb
else
  16 * 1024; // RELEASE = 16kb // reader stack // 8-16 kb without ssl usage, 32 kb when use ssl

const WS_WRITER_STACK = 8 * 1024; // stack size for writer task // 8 kb without ssl usage, 32 kb when use ssl


var global_pubsub: PubSub = undefined;


// WebSocket handlers
fn on_ws_connect(session: *WsSession) !void{
  try global_pubsub.subscribe("general", session);
  try session.scheduleSend("Welcome! You are joined to 'general'. Send 'room:message' to chat.");
  
  std.log.info("WebSocket connected and joined 'general' chat", .{});
}


fn on_ws_close(session: *WsSession) void{
  global_pubsub.removeConn(session);
  //std.log.info("WS closed: code={d}, reason={s}", .{ code, reason });
  std.log.info("WS closed, client removed from all chats", .{  });
}


fn on_ws_message(session: *WsSession, data: []const u8) !void{
  std.log.info("WS server received message: '{s}' (len: {d})", .{data, data.len});
  
  if (std.mem.indexOfScalar(u8, data, ':')) |idx| {
      const command_or_chat = data[0..idx];
      const msg_content = data[idx+1..];
      
        if (std.mem.eql(u8, command_or_chat, "join")) { // "join:chatname"
            try global_pubsub.subscribe(msg_content, session);
            try session.scheduleSend("Joined chat");
            return;
        }
        
        if (std.mem.eql(u8, command_or_chat, "leave")) { // "leave:chatname"
            global_pubsub.unsubscribe(msg_content, session);
            try session.scheduleSend("Left chat");
            return;
        }
        
        //const formatted_msg = try std.fmt.allocPrint(conn.runtime.allocator, "Msg in {s}: {s}", .{command_or_chat, msg_content}); // pub to chatname
        //defer conn.runtime.allocator.free(formatted_msg);
        const formatted_msg = try std.fmt.allocPrint(session.allocator, "Msg in {s}: {s}", .{command_or_chat, msg_content}); // pub to chatname
        defer session.allocator.free(formatted_msg);
        
        global_pubsub.publish(command_or_chat, formatted_msg, session); // send message everybody (but not to sender)
        //global_pubsub.publish("general", "System: Server is shutting down", null); // "system" message without sender conn
        
    } else {
        try session.scheduleSend("Format: 'chatname:message' or 'join:chatname'");
    }
  std.log.info("WS <- {s}", .{data});
}


// optional -- not required
fn on_ws_disconnect(session: *WsSession) void{
  global_pubsub.removeConn(session);
  std.log.info("WebSocket disconnected, client removed from all chats", .{});
}


// HTTP fallback
fn on_request(ctx: *const zzz.Context, _: void) !zzz.HTTP.Respond {
    const res = ctx.response;
    res.status = .OK;
    res.mime = zzz.HTTP.Mime.HTML;
    res.body =
      \\<html>
      \\<head><title>zzz + WebSocket + PubSub</title></head>
      \\<body>
      \\<h1>WebSocket PubSub Test</h1>
      \\<script>
      \\const ws = new WebSocket("ws://localhost:3010/ws");
      \\ws.onmessage = (e) => console.log("ws <- ", e.data);
      \\ws.onopen = () => ws.send("Hello from browser!");
      \\ws.onclose = (e) => console.log("ws closed", e);
      \\</script>
      \\</body>
      \\</html>
    ;
    return .standard;
}


fn on_ws_endpoint(ctx: *const zzz.Context, _: void) !zzz.HTTP.Respond {
  return handle_upgrade(ctx, .{
      .on_connect = on_ws_connect,
      .on_message = on_ws_message,
      .on_close = on_ws_close,
      //.on_disconnect = on_ws_disconnect, // optional
    },
    WS_WRITER_STACK // stack size for writer task
  );
}


pub fn main() !void{
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    global_pubsub = PubSub.init(allocator);
    defer global_pubsub.deinit();
    
    const socket = try Socket.init(.{ .tcp = .{ .host = HOST, .port = PORT } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024); // max conn count that are waiting in accept queue
    
    var tardy = try zzz.tardy.Tardy(.auto).init(allocator, .{});
    //var tardy = try TardyType.init(allocator, .{ .threading = .single });
    defer tardy.deinit();
    
    const home_route = zzz.HTTP.Route.init("/").get({}, on_request);
    const ws_route = zzz.HTTP.Route.init("/ws").get({}, on_ws_endpoint);
    const layers = &[_]zzz.HTTP.Layer{
      home_route.layer(),
      ws_route.layer(),
    };
    
    const router = try zzz.Router.init(allocator, layers, .{ .not_found = on_request });
    // no defer router - lifetime per server work
    
    var server = zzz.Server.init(.{ .stack_size = STACK_SIZE }); // stack for http requests
    
    const Entry_Params = struct {
      server: *zzz.Server,
      router: *const zzz.Router,
      socket: Socket,
    };
    
    try tardy.entry(
      Entry_Params{ .server = &server, .router = &router, .socket = socket },
      struct {
        fn entry(rt: *zzz.tardy.Runtime, p: Entry_Params) !void {
          try p.server.serve(rt, p.router, .{ .normal = p.socket });
        } // end fn entry
    }.entry);
}

