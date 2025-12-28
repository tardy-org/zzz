const std = @import("std");

const zzz = @import("zzz");
const Socket = zzz.tardy.Socket;
const File = zzz.tardy.File;
const Dir = zzz.tardy.Dir;
const Timer = zzz.tardy.Timer; // for cleaner

const websocket = zzz.websocket;
const WsSession = zzz.WsSession;
const handle_upgrade = zzz.handle_upgrade;

const Bert = @import("bert.zig").Bert; // https://github.com/221V/zig_erl_bert  for BERT encode-decode
const Bert_Value = @import("bert.zig").Bert_Value;


const PORT = 3010;
const HOST = "0.0.0.0";

//const WS_STACK_SIZE = 1 * 1024 * 1024; // DEBUG = 1mb
const WS_STACK_SIZE = 16 * 1024; // RELEASE = 16kb


const ExtensionsLimits = struct {
  //ext: []const u8,
  exts: []const []const u8, // for set few filetypes with same max size
  size: usize,
};

const UploadConfig = struct {
  save_path_temp: []const u8 = "uploads/temp",
  save_path_root: []const u8 = "uploads",
  max_size_default: usize = 10 * 1024 * 1024, // default 10Mb
  
  allow_extensions: ?[]const []const u8 = &.{ ".jpg", ".png", ".gif", ".txt", ".pdf", ".mp3", ".mp4", ".avi" },
  deny_extensions: ?[]const []const u8 = &.{ ".exe", ".sh" },
  
  extension_limits: []const ExtensionsLimits = &.{
    .{ .exts = &.{ ".txt" }, .size = 1 * 1024 * 1024 }, // 1Mb max
    .{
       .exts = &.{ ".jpg", ".png", ".gif", ".pdf" },
       .size = 5 * 1024 * 1024 // 5Mb max
    },
    .{
       .exts = &.{ ".mp3", ".mp4" },
       .size = 50 * 1024 * 1024 // 50Mb max
    },
    .{ .exts = &.{ ".avi" }, .size = 2 * 1024 * 1024 * 1024 }, // 2Gb max
  },
  
  ttl_seconds: i64 = 24 * 60 * 60, // 24 hours for temp files
};

const config = UploadConfig{};


// session state for uploads
const UploadState = struct {
  file: File,
  path: []const u8,
  path_done: []const u8,
  total_size: usize,
  current_size: usize,
  last_update: i64,
};


// global or per-session map // use per-session user_data custom struct
const SessionContext = struct {
  uploads: std.StringHashMap(UploadState),
  allocator: std.mem.Allocator,
};


// helpers

fn checkLimits(name: []const u8, size: usize) !void {
    const raw_ext = std.fs.path.extension(name);
    
    var ext_buf: [10]u8 = undefined; // 10 chars length for files extension
    if (raw_ext.len >= ext_buf.len) return error.ExtensionTooLong;
    
    const lower_ext = std.ascii.lowerString(&ext_buf, raw_ext);
    const ext = std.mem.trim(u8, lower_ext, &[_]u8{ 0, ' ', '\t', '\r', '\n' });
    
    std.log.info("CheckLimits: file='{s}', raw_ext='{s}', normalized_ext='{s}', size={d}", .{ name, raw_ext, ext, size });
    
    if (config.deny_extensions) |list| { // check blacklist
        for (list) |denied| {
            if (std.mem.eql(u8, ext, denied)) return error.ExtensionDenied;
        }
    }
    
    if (config.allow_extensions) |list| { // check whitelist
        var found = false;
        for (list) |allowed| {
            if (std.mem.eql(u8, ext, allowed)) { found = true; break; }
        }
        if (!found){
          std.log.err("CheckLimits: Extension '{s}' not found in allow list", .{ext});
          return error.ExtensionNotAllowed;
        }
    }
    
    var limit = config.max_size_default;
    
    outer: for (config.extension_limits) |group| { // lets check file size limit // label :outer for exit both loops
      for (group.exts) |group_ext| {
        if (std.mem.eql(u8, ext, group_ext)) {
            limit = group.size;
            //std.log.info("CheckLimits: Matched group for '{s}', setting limit to {d}", .{group_ext, limit});
            break :outer; // limit found, stop search
        }
      }
    }
    
    //std.log.info("CheckLimits: Checking size {d} vs limit {d}", .{size, limit});
    if (size > limit) {
      std.log.err("CheckLimits: FAILED. Size {d} > Limit {d}", .{size, limit});
      return error.FileTooLarge;
    }
}


fn getSavePath(allocator: std.mem.Allocator, filename: []const u8, total_size: usize) ![]const u8 {
    //const ts = std.time.timestamp(); // construct path: root/timestamp_file
    //const basename = std.fs.path.basename(filename);
    //std.log.info("getSavePath: config.save_path_root = '{s}', basename = '{s}', ts = {d}", .{ config.save_path_root, basename, ts });
    
    var hasher = std.hash.Wyhash.init(0); // construct path: root/<HASH>.<EXT>
    hasher.update(filename);
    hasher.update(std.mem.asBytes(&total_size));
    const hash = hasher.final();
    
    const raw_ext = std.fs.path.extension(filename);
    
    var ext_buf: [10]u8 = undefined; // 10 chars length for files extension
    //if (raw_ext.len >= ext_buf.len) return error.ExtensionTooLong;
    
    const ext = if (raw_ext.len < ext_buf.len)
      std.ascii.lowerString(&ext_buf, raw_ext)
    else
      raw_ext;
    
    //std.log.info("getSavePath: config.save_path_root = '{s}', ext = '{s}', ts = {d}", .{ config.save_path_root, ext, ts });
    std.log.info("getSavePath: config.save_path_root = '{s}', hash = '{x}', ext = {s}", .{ config.save_path_root, hash, ext });
    return std.fmt.allocPrint(allocator, "{s}/{x}{s}", .{config.save_path_root, hash, ext}); // .{config.save_path_root, ts, ext}); // .{config.save_path_root, ts, basename});
}


fn getFileInfo(allocator: std.mem.Allocator, filename: []const u8, total_size: usize, is_temp: bool) !struct{ path: []const u8, id: []const u8 } {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(filename);
    hasher.update(std.mem.asBytes(&total_size));
    const hash = hasher.final();
    
    const ext = std.fs.path.extension(filename);
    const id_str = try std.fmt.allocPrint(allocator, "{x}", .{hash}); // id = hex hash
    
    const root = if (is_temp) config.save_path_temp else config.save_path_root;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{root, id_str, ext});
    
    return .{ .path = path, .id = id_str };
}


fn cleanup_task(rt: *zzz.tardy.Runtime) !void {
    std.log.info("Cleanup task started", .{});
    while (true) {
        try Timer.delay(rt, .{ .seconds = 3600 }); // sleep 1 hour
        
        std.log.info("Cleanup task: Scanning for stale uploads...", .{});
        var dir = std.fs.cwd().openDir(config.save_path_temp, .{ .iterate = true }) catch continue;
        defer dir.close();
        
        var iter = dir.iterate();
        const now = std.time.timestamp();
        
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file) {
                const stat = dir.statFile(entry.name) catch continue;
                const mtime_sec = @divFloor(stat.mtime, std.time.ns_per_s); // time of last modification, in ns
                
                if (now - mtime_sec > config.ttl_seconds) {
                    std.log.info("Cleanup task: Deleting stale file {s} (age: {d}s)", .{entry.name, now - mtime_sec});
                    dir.deleteFile(entry.name) catch |e| std.log.err("Cleanup task delete error: {s}", .{ @errorName(e) });
                }
            }
        }
    }
}


// WS Handlers

fn on_ws_connect(session: *WsSession) !void {
    std.log.info("Client connected", .{});
    
    const ctx = try session.allocator.create(SessionContext); // init session context
    ctx.* = .{
      .uploads = std.StringHashMap(UploadState).init(session.allocator),
      .allocator = session.allocator,
    };
    
    session.context = ctx;
}

fn on_ws_message(session: *WsSession, data: []const u8) !void {
  // we expect binary BERT data -- if text, ignore or log
  _ = session;
  std.log.info("Received Text (ignoring): {s}", .{data});
}


// helper for on_ws_binary file_upload handle
fn handleInitUpload(allocator: std.mem.Allocator, ctx: *SessionContext, name: []const u8, total: usize) !struct { offset: usize, response_id: []const u8 } {
  std.log.info("DEBUG: handleInitUpload start for {s}", .{name});
  
  checkLimits(name, total) catch |e| {
    std.log.err("Limit check failed: {s}", .{ @errorName(e) });
    return e;
  };
  
  const info_temp = try getFileInfo(ctx.allocator, name, total, true);
  const info_done = try getFileInfo(ctx.allocator, name, total, false); // for check maybe already uploaded
  
  std.log.info("DEBUG: Generated ID: {s}", .{info_temp.id});
  
  std.fs.cwd().makePath(config.save_path_root) catch {}; // ensure dir exists
  std.fs.cwd().makePath(config.save_path_temp) catch {};
  
  if (ctx.uploads.fetchRemove(info_temp.id)) |kv| { // close existing handle if resuming
    std.log.info("Resuming active session: closing old handle for {s}", .{name});
    kv.value.file.close_blocking();
    
    ctx.allocator.free(kv.key);
    ctx.allocator.free(kv.value.path);
    ctx.allocator.free(kv.value.path_done);
  }
  
  if (std.fs.cwd().access(info_done.path, .{})) { // already uploaded
    std.log.info("File already uploaded: {s}", .{info_done.path});
    return .{ .offset = total, .response_id = info_temp.id }; // success, done
    
    //ctx.allocator.free(info_temp.path);
    //ctx.allocator.free(info_temp.id);
    //ctx.allocator.free(info_done.path);
    //ctx.allocator.free(info_done.id);
  
  }else |_| {} // check temp (resume)
  
  var file_exists = false;
  var existing_size: usize = 0;
  
  //const existing_file_result = std.fs.cwd().openFile(info_temp.path, .{ .mode = .read_write }); // try to open temp file that exists
  //if(existing_file_result) |f| { // check if exists for resume
  if( std.fs.cwd().openFile(info_temp.path, .{ .mode = .read_write }) ) |f| { // check if exists for resume
    const stat = f.stat() catch |e| {
      std.log.err("Stat failed: {s}", .{ @errorName(e) });
      f.close();
      return e;
    };
    //const stat = try f.stat();
    
    if(stat.size < total){  // resume - not uploded yet
      file_exists = true;
      existing_size = stat.size;
      f.close();
    
    } else if(stat.size == total){ // already uploaded ok
      f.close();
      std.log.info("Temp file complete, returning done", .{});
      return .{ .offset = total, .response_id = info_temp.id }; // temp file done
      
      //ctx.allocator.free(info_temp.path);
      //ctx.allocator.free(info_temp.id);
      //ctx.allocator.free(info_done.path);
      //ctx.allocator.free(info_done.id);
    
    } else { // error? rewrite
      f.close();
    }
  
  }else |err| { // file not exists or access error
    if (err != error.FileNotFound) {
      std.log.err("Failed to check existing file '{s}': {s}", .{ info_temp.path, @errorName(err) }); // std.log.warn("OpenFile warning (not fatal): {s}", .{ @errorName(err) });
      return err; // return err and not rewrite
    }
  }
  
  std.log.info("DEBUG: Opening file: {s}... Exists: {}", .{ info_temp.path, file_exists });
  
  const file = if (file_exists) // open for writing
    try std.fs.cwd().openFile(info_temp.path, .{ .mode = .read_write })
  else
    try std.fs.cwd().createFile(info_temp.path, .{});
  
  if(file_exists){ // if resuming or new file
    try file.seekTo(existing_size);
    std.log.info("RESUMING: {s} -> {d}/{d}", .{info_temp.id, existing_size, total});
  }else{
    std.log.info("NEW: {s}", .{info_temp.id});
  }
  
  // Convert std.fs.File to tardy.File if needed, for non-blocking file I/O
  // Better use tardy.File, but for simplicity we use std.fs.File handle wrapped
  const tardy_file = zzz.tardy.File.from_std(file);
  const id_key = try allocator.dupe(u8, info_temp.id);
  
  try ctx.uploads.put(id_key, .{
    .file = tardy_file,
    .path = info_temp.path,      // here write
    .path_done = info_done.path, // here move when upload 100%
    .total_size = total,
    .current_size = if(file_exists) existing_size else 0,
    .last_update = std.time.milliTimestamp(),
  });
  
  //ctx.allocator.free(info_done.id);
  std.log.info("DEBUG: Init success, returning", .{});
  return .{ .offset = if(file_exists) existing_size else 0, .response_id = info_temp.id };
}

fn on_ws_binary(session: *WsSession, data: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(session.allocator); // temp arena for parsing
    defer arena.deinit();
    const temp_alloc = arena.allocator();
    
    var b = Bert.init(temp_alloc);
    const val = b.decode(data) catch |e| { // for file data Bert_Value must be Tuple{ftp, id, ..., data, status}
      std.log.err("BERT Decode Error: {s}", .{ @errorName(e) });
      return;
    };
    
    switch(val){
      .tuple => |elems| {
        if(elems.len != 13){ return; } // not file data // n2o ftp protocol has 13 elements
        
        const atom_tag = elems[0];
        switch (atom_tag) {
          .atom => |s| if (!std.mem.eql(u8, s, "ftp")) return, // check 'ftp' atom
          else => return,
        }
        
        const id = try get_binary_str(elems[1]);
        const name = try get_binary_str(elems[3]);
        const total = try get_int_usize(elems[8]);
        const offset = try get_int_usize(elems[9]);
        const bin_data = try get_binary_str(elems[11]);
        const status = try get_binary_str(elems[12]);
        
        const ctx_ptr = session.context orelse return; // get upload context
        const ctx: *SessionContext = @ptrCast(@alignCast(ctx_ptr));
        
        var reply_status: []const u8 = "send";
        var current_offset: usize = 0;
        var response_id: []const u8 = id; // client id by default
        
        if(std.mem.eql(u8, status, "init")){ // start upload
          std.log.info("Init upload: {s} ({d} bytes)", .{name, total});
          
          if( handleInitUpload(ctx.allocator, ctx, name, total) ) |res| {
            current_offset = res.offset;
            response_id = res.response_id;
            std.log.info("WS: Init OK, offset={d}", .{current_offset});
          } else |err| {
            std.log.err("Init failed with exception: {s}", .{ @errorName(err) });
            reply_status = "error";
          }
        
        
        }else if(std.mem.eql(u8, status, "send")){ // chunk received
          if (ctx.uploads.getPtr(id)) |state| { // here id must be server id because client has update it after init
            if (offset != state.current_size) { // validate offset
                current_offset = state.current_size; // client out of sync? tell him where we are
            }else{ // write data
                _ = try state.file.write_all(session.conn.runtime, bin_data, null);
                state.current_size += bin_data.len;
                state.last_update = std.time.milliTimestamp();
                current_offset = state.current_size;
                
                if (state.current_size >= state.total_size) {
                    std.log.info("Upload complete. Move to: {s}", .{state.path_done});
                    state.file.close_blocking();
                    
                    std.fs.cwd().rename(state.path, state.path_done) catch |e| {
                      std.log.err("Failed to move file: {s}", .{ @errorName(e) }); // maybe todo send err status to client.. but file already uploaded
                    };
                    
                    if(ctx.uploads.fetchRemove(id)) |kv| {
                      ctx.allocator.free(kv.key); // id
                      ctx.allocator.free(kv.value.path);
                      ctx.allocator.free(kv.value.path_done);
                    }
                    
                    //_ = ctx.uploads.remove(id);
                }
            }
          
          }else{
            reply_status = "error"; // upload session not found
          }
        }
        
        var reply_tuple_items = [_]Bert_Value{ // encode Reply
          b.atom("ftp") catch unreachable,
          b.binary(response_id) catch unreachable,
          b.binary("") catch unreachable, // sid
          b.binary("") catch unreachable, // name (empty for ack)
          b.binary("") catch unreachable,
          b.binary("") catch unreachable,
          b.binary("") catch unreachable,
          b.binary("") catch unreachable,
          b.int(@intCast(total)),
          b.int(@intCast(current_offset)),
          b.int(0), // block
          b.binary("") catch unreachable, // data
          b.binary(reply_status) catch unreachable, // status
        };
        
        std.log.info("WS: Sending Reply status='{s}' offset={d}", .{reply_status, current_offset});
        const encoded = try b.encode(try b.tuple(&reply_tuple_items));
        
        session.scheduleSendBinary(encoded) catch |e| {
          std.log.err("WS: scheduleSendBinary FAILED: {s}", .{ @errorName(e) });
        };
      },
      else => {},
    }
}

// helpers
fn get_binary_str(v: Bert_Value) ![]const u8 {
  return switch(v) { .binary => |b| b, else => error.NotBinary };
}

fn get_int_usize(v: Bert_Value) !usize {
  return switch(v) {
    //.int => |i| @intCast(i),
    //.big_int => 0,
    .int => |i| if (i < 0) error.NegativeValue else @intCast(i),
    .big_int => |bi| bi.toConst().toInt(usize) catch error.IntTooLarge,
    else => error.NotInt
  };
}


fn on_ws_close(session: *WsSession) void {
    if (session.context) |ptr| {
        session.context = null; // clean context for avoid double free error
        
        const ctx: *SessionContext = @ptrCast(@alignCast(ptr));
        
        var iter = ctx.uploads.iterator();
        while (iter.next()) |entry| { // clean up open files
            entry.value_ptr.file.close_blocking();
        }
        ctx.uploads.deinit();
        
        session.allocator.destroy(ctx);
    }
}


// HTTP Handler
fn on_request(ctx: *const zzz.Context, _: void) !zzz.HTTP.Respond {
    const res = ctx.response;
    res.status = .OK;
    res.mime = zzz.HTTP.Mime.HTML;
    // embed the JS client
    res.body = 
        \\<!DOCTYPE html><html><head><meta charset="UTF-8"><style>body{font-family:sans-serif;padding:20px}</style></head>
        \\<body>
        \\<h2>zzz + WS File Upload Example</h2>
        \\<input type="file" multiple onchange="selectFiles(this)">
        \\<div id="ftp-status" style="margin-top:20px"></div>
        \\<!-- <script src="/static/BigInteger.min.js" defer></script> -->
        \\<script src="/static/bert_ftp.js" defer></script>
        \\<script src="/static/form.js" defer></script>
        \\</body></html>
    ;
    return .standard;
}

fn on_ws_endpoint(ctx: *const zzz.Context, _: void) !zzz.HTTP.Respond {
    return handle_upgrade(ctx, .{
        .on_connect = on_ws_connect,
        .on_message = on_ws_message,
        .on_binary = on_ws_binary,
        .on_close = on_ws_close,
    }, WS_STACK_SIZE);
}


pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    
    const socket = try Socket.init(.{ .tcp = .{ .host = HOST, .port = PORT } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);

    const TardyType = zzz.tardy.Tardy(.auto);
    var tardy = try TardyType.init(allocator, .{});
    defer tardy.deinit();

    try tardy.entry(&socket, struct {
        fn entry(rt: *zzz.tardy.Runtime, s: *const Socket) !void {
            const server_config = zzz.ServerConfig{ .stack_size = 64 * 1024 };
            
            const home_route = zzz.HTTP.Route.init("/").get({}, on_request);
            const ws_route = zzz.HTTP.Route.init("/ws").get({}, on_ws_endpoint);
            
            //const js_route = zzz.HTTP.FsDir.serve("/static", zzz.tardy.Dir.cwd()); // bert_ftp.js
            const std_static_dir = try std.fs.cwd().openDir("examples_ws/static", .{ .iterate = true });
            const static_dir = zzz.tardy.Dir.from_std(std_static_dir);
            const js_route = zzz.HTTP.FsDir.serve("/static", static_dir); // bert_ftp.js
            
            const layers = &[_]zzz.HTTP.Layer{ home_route.layer(), ws_route.layer(), js_route };
            
            const router = try rt.allocator.create(zzz.Router);
            router.* = try zzz.Router.init(rt.allocator, layers, .{ .not_found = on_request });

            const provisions = try rt.allocator.create(zzz.tardy.Pool(zzz.Provision));
            provisions.* = try zzz.tardy.Pool(zzz.Provision).init(rt.allocator, 1024, .static);
            const byte_count = provisions.items.len * @sizeOf(zzz.Provision);
            @memset(@as([*]u8, @ptrCast(provisions.items.ptr))[0..byte_count], 0);
            
            const connection_count = try rt.allocator.create(usize);
            connection_count.* = 0;
            const accept_queued = try rt.allocator.create(bool);
            accept_queued.* = false;
            
            try rt.spawn(
              .{ rt, server_config, router, zzz.secsock.SecureSocket.unsecured(s.*), provisions, connection_count, accept_queued },
              zzz.Server.main_frame,
              server_config.stack_size
            );
            
            //try rt.spawn(.{rt}, cleanup_task, 64 * 1024);
        }
    }.entry);
}

