
// Pub/Sub for WS

const std = @import("std");
const zzz = @import("../lib.zig"); // "zzz" // for zzz.Context
const Conn = @import("websocket.zig").Conn;
const SecureSocket = zzz.secsock.SecureSocket;


pub const UserWsHandler = struct {
  on_connect: ?*const fn (session: *WsSession) anyerror!void = null,
  on_message: ?*const fn (session: *WsSession, data: []const u8) anyerror!void = null,
  on_close: ?*const fn (session: *WsSession) void = null,
  on_disconnect: ?*const fn (session: *WsSession) void = null,
};


pub const WsSession = struct { // for safe multithread use Pub/Sub
    conn: Conn,
    socket_owned: SecureSocket, // owned copy of socket structure (avoid use-after-free error)
    outbox: std.ArrayList([]const u8), // messages queue that need to send to client with conn
    mutex: std.Thread.Mutex,
    writer_task_id: usize = 0, // task id for send in native thread
    active: bool = true, // flag for to stop writer_task on disconnect
    allocator: std.mem.Allocator,
    writer_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // for avoid race condition
    handler: UserWsHandler, // for access callbacks inside session
    
    pub fn init(allocator: std.mem.Allocator, conn: Conn, handler: UserWsHandler) WsSession {
        return .{
            .conn = conn,
            .socket_owned = conn.socket.*,
            .outbox = std.ArrayList([]const u8).init(allocator),
            .mutex = .{},
            .allocator = allocator,
            .handler = handler,
        };
    }

    pub fn deinit(self: *WsSession) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.outbox.items) |msg| {
            self.allocator.free(msg);
        }
        self.outbox.deinit();
    }

    pub fn scheduleSend(self: *WsSession, data: []const u8) !void { // function for safe call from any thread
        self.mutex.lock();
        if (!self.active) {
            self.mutex.unlock();
            return error.Closed;
        }
        
        const msg_copy = try self.allocator.dupe(u8, data); // copy msg to heap
        try self.outbox.append(msg_copy);
        self.mutex.unlock();
        
        try self.conn.runtime.trigger(self.writer_task_id); // conn.runtime.trigger is thread-safe // this is task-writer in target thread
    }
};


pub const PubSub = struct {
    topics: std.StringHashMap(std.ArrayList(*WsSession)), // Topic Name -> List of Connections
    lock: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PubSub {
        return .{
            .topics = std.StringHashMap(std.ArrayList(*WsSession)).init(allocator),
            .lock = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PubSub) void {
        self.lock.lock();
        defer self.lock.unlock();
        
        var iter = self.topics.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.topics.deinit();
    }

    pub fn subscribe(self: *PubSub, topic: []const u8, session: *WsSession) !void {
        self.lock.lock();
        defer self.lock.unlock();

        const entry = try self.topics.getOrPut(topic);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.allocator.dupe(u8, topic);
            entry.value_ptr.* = std.ArrayList(*WsSession).init(self.allocator);
        }
        
        for (entry.value_ptr.items) |existing| { // not add doublibgs
            if (existing == session) return;
        }
        
        try entry.value_ptr.append(session);
        std.log.debug("PubSub: Client subscribed to '{s}'", .{topic});
    }

    pub fn unsubscribe(self: *PubSub, topic: []const u8, session: *WsSession) void {
        self.lock.lock();
        defer self.lock.unlock();

        if (self.topics.getPtr(topic)) |list| {
            for (list.items, 0..) |s, i| {
                if (s == session) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }
        
        //if (list.items.len == 0) { // del group if empty
        //    list.deinit();
        //    if (self.topics.fetchRemove(topic)) |kv| {
        //        self.allocator.free(kv.key);
        //    }
        //}
    }
    
    
    pub fn removeConn(self: *PubSub, session: *WsSession) void { // delete connection/client from all groups - call on_disconnect
        self.lock.lock();
        defer self.lock.unlock();
        
        var iter = self.topics.iterator();
        while (iter.next()) |entry| {
            const list = entry.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i] == session) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
             }
        }
    }
    
    
    pub fn publish(self: *PubSub, topic: []const u8, message: []const u8, sender: ?*WsSession) void {
        self.lock.lockShared(); // shared lock for read
        defer self.lock.unlockShared();

        if (self.topics.get(topic)) |list| {
            for (list.items) |session| {
                if (sender) |s| { // do not send for the sender
                    if (s == session) continue;
                }
                
                session.scheduleSend(message) catch |e| { // todo repeat send on error (one laggy/dead client not blocks all)
                    std.log.warn("PubSub send failed: {}", .{e});
                };
            }
        }
    }
};


// helpers

fn writer_task(session: *WsSession) !void { // send message in same thread with conn
    session.writer_task_id = session.conn.runtime.current_task.?; // save task id for PubSub
    defer session.writer_done.store(true, .release);

    while (true) {
        session.mutex.lock();
        if (!session.active) {
            session.mutex.unlock();
            break;
        }
        
        const batch = try session.outbox.toOwnedSlice();
        session.mutex.unlock();
        
        if (batch.len > 0) {
          for (batch) |msg| {
            session.conn.send(msg) catch |e| {
                std.log.debug("WS Writer Error: {s}", .{ @errorName(e) });
            };
            session.allocator.free(msg);
          }
          session.allocator.free(batch);
        }
        try session.conn.runtime.scheduler.trigger_await();
    }
}


pub fn handle_upgrade(ctx: *const zzz.Context, user_handler: UserWsHandler, stack_size_writer: usize) !zzz.HTTP.Respond {
    const req = ctx.request;
    
    const upgrade = req.headers.get("Upgrade");
    if (upgrade == null or !std.mem.eql(u8, upgrade.?, "websocket")) {
        ctx.response.status = .@"Bad Request";
        //ctx.response.body = "Expected WebSocket Upgrade";
        return .standard;
    }
    
    const key = req.headers.get("Sec-WebSocket-Key") orelse return .standard;
    const ext = req.headers.get("Sec-WebSocket-Extensions");
    
    var header_buf = std.ArrayList(u8).init(ctx.allocator);
    defer header_buf.deinit();
    
    const res = try zzz.websocket.upgrade(&ctx.socket, ctx.runtime, ctx.allocator, key, ext, header_buf.writer());
    _ = try ctx.socket.send_all(ctx.runtime, header_buf.items);
    
    const session = try std.heap.page_allocator.create(WsSession);
    session.* = WsSession.init(std.heap.page_allocator, res.conn, user_handler);
    
    session.conn.socket = &session.socket_owned; // use heap instead stack
    session.conn.user_data = session; // for not use global maps that locks
    
    try ctx.runtime.spawn(.{ session }, writer_task, stack_size_writer);
    
    const internal_handler = zzz.websocket.Handler{
        .on_message = struct {
            fn wrapper(c: Conn, d: []const u8) !void {
                const s: *WsSession = @ptrCast(@alignCast(c.user_data)); // get session from user_data
                if (s.handler.on_message) |f| try f(s, d);
            }
        }.wrapper,
        
        .on_close = struct {
            fn wrapper(c: Conn, code: u16, reason: []const u8) !void {
                _ = code;
                _ = reason;
                const s: *WsSession = @ptrCast(@alignCast(c.user_data));
                if (s.handler.on_close) |f| f(s);
            }
        }.wrapper,
        
        .on_disconnect = struct {
            fn wrapper(c: Conn) !void {
                const s: *WsSession = @ptrCast(@alignCast(c.user_data));
                if (s.handler.on_close) |f| f(s);
            }
        }.wrapper,
    };
    
    
    if (user_handler.on_connect) |f| {
        f(session) catch |e| { // clean if conn failed
            std.log.err("WS on_connect error: {s}", .{ @errorName(e) });
            
            session.active = false;
            ctx.runtime.trigger(session.writer_task_id) catch {};
            
            while(!session.writer_done.load(.acquire)){
              try zzz.tardy.Timer.delay(ctx.runtime, .{ .nanos = 1000 });
            }
            
            session.deinit();
            std.heap.page_allocator.destroy(session);
            
            std.log.info("WebSocket Loop finished and memory freed", .{});
            return .close;
        };
    }
    
    //zzz.websocket.runLoop(session.conn, internal_handler, ctx.runtime.allocator) catch |err| { // sync loop
    zzz.websocket.runLoop(session.conn, internal_handler, std.heap.page_allocator) catch |err| { // sync loop
      if (err != error.Closed){
        std.log.err("WebSocket RunLoop Error: {s}", .{ @errorName(err) });
      }
      //if (err == error.Closed) {
      //  std.log.info("WebSocket closed by browser", .{});
      //}
    };
    
    //std.log.info("Closing session...", .{});
    
    session.mutex.lock();
    session.active = false;
    session.mutex.unlock();
    
    ctx.runtime.trigger(session.writer_task_id) catch {};
    
    while (!session.writer_done.load(.acquire)) { // waiting while writer_task will be done
      try zzz.tardy.Timer.delay(ctx.runtime, .{ .nanos = 1_000_000 }); // 1 ms
    }
    
    session.deinit();
    std.heap.page_allocator.destroy(session);
    
    std.log.info("WebSocket Loop finished and memory freed", .{});
    return .close;
}

