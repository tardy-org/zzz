
// http rest example - Content Negotiation - return different data types depending on client request

const std = @import("std");

const zzz = @import("zzz");

const http = zzz.HTTP;
const Socket = zzz.tardy.Socket;


const PORT = 9862; // 8080;
const HOST = "0.0.0.0";


const STACK_SIZE = if (@import("builtin").mode == .Debug)
  1 * 1024 * 1024 // DEBUG = 1mb
else
  32 * 1024; // RELEASE = 32kb


const User = struct {
  id: u32,
  name: []const u8,
  email: []const u8,
};


fn on_request(ctx: *const http.Context, _: void) !http.Respond {
  if(ctx.request.method.? == .GET){
    return ctx.response.apply(.{
      .status = .OK,
      .mime = http.Mime.HTML,
      .body =
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="UTF-8">
        \\</head>
        \\<body>
        \\<h3>zzz REST Content Negotiation</h3>
        \\<select id="acceptType">
        \\<option value="application/json">JSON</option>
        \\<option value="text/html">HTML</option>
        \\<option value="text/plain">Plain Text</option>
        \\</select>
        \\<button onclick="send()">Send Request</button>
        \\<hr><div id="view" style="border:1px solid #ccc;padding:10px"></div>
        \\<script>
        \\async function send(){
        \\  const type = document.getElementById('acceptType').value;
        \\  const res = await fetch('/', { method: 'POST', headers: { 'Accept': type } });
        \\  const contentType = res.headers.get('content-type');
        \\  console.log('Response Received Type == ', contentType);
        \\  const html_or_text = await res.text();
        \\  const cont = document.getElementById('view');
        \\  if(contentType.includes('html')){
        \\    cont.insertAdjacentHTML('beforeend', html_or_text);
        \\  }else{
        \\    cont.insertAdjacentText('beforeend', html_or_text);
        \\    cont.insertAdjacentHTML('beforeend', '<br>');
        \\  }
        \\}
        \\</script>
        \\</body>
        \\</html>
    });
  } // else POST request
  
  const user = User{ .id = 1, .name = "Alice", .email = "alice@example.com" };
  const accept = ctx.request.headers.get("accept") orelse "*/*";
  
  
  if(std.mem.indexOf(u8, accept, "application/json") != null){ // if expect json
    const body = try std.json.stringifyAlloc(ctx.allocator, user, .{});
    return ctx.response.apply(.{
      .status = .OK,
      .mime = http.Mime.JSON,
      .body = body,
    });
  }
  
  
  if(std.mem.indexOf(u8, accept, "text/html") != null){ // if expect html
    const body = try std.fmt.allocPrint(ctx.allocator,
      "<p>User: {s} has ID: {d}</p>",
      .{ user.name, user.id });
    
    return ctx.response.apply(.{
      .status = .OK,
      .mime = http.Mime.HTML,
      .body = body,
    });
  }
  
  
  return ctx.response.apply(.{  // else plain text
    .status = .OK,
    .mime = http.Mime.TEXT,
    .body = try std.fmt.allocPrint(ctx.allocator, "User: {s} (ID: {d})", .{ user.name, user.id }),
  });
}



pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  const allocator = gpa.allocator();
  defer _ = gpa.deinit();
  
  const socket = try Socket.init(.{ .tcp = .{ .host = HOST, .port = PORT } });
  defer socket.close_blocking();
  try socket.bind();
  try socket.listen(1024); // max conn count that are waiting in accept queue
  
  var tardy = try zzz.tardy.Tardy(.auto).init(allocator, .{});
  defer tardy.deinit();
  
  try tardy.entry(&socket, struct {
    fn entry(rt: *zzz.tardy.Runtime, s: *const Socket) !void {
      const config = zzz.ServerConfig{ .stack_size = STACK_SIZE };
      const router = try rt.allocator.create(zzz.Router);
      router.* = try zzz.Router.init(rt.allocator, &.{
        http.Route.init("/").get({}, on_request).post({}, on_request).layer(),
      }, .{ .not_found = on_request });
      
      const provisions = try rt.allocator.create(zzz.tardy.Pool(zzz.Provision)); // use heap instead of stack
      provisions.* = try zzz.tardy.Pool(zzz.Provision).init(rt.allocator, 1024, .static); // 1024 = pool size
      @memset(std.mem.sliceAsBytes(provisions.items), 0); // set zeros -- initialized = false
      
      const conn_count = try rt.allocator.create(usize);
      conn_count.* = 0;
      const accept_q = try rt.allocator.create(bool);
      accept_q.* = false;
      
      try rt.spawn(.{ rt, config, router, zzz.secsock.SecureSocket.unsecured(s.*), provisions, conn_count, accept_q }, zzz.Server.main_frame, config.stack_size);
    } // end fn entry
  }.entry);
}

