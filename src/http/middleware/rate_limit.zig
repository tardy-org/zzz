//TODO: add examples utilizing this to prevent bitrot
/// Rate Limiting Middleware.
///
/// Provides a IP-matching Bucket-based Rate Limiter.
pub fn RateLimiting(config: *Config) Middleware.Layer {
    const func: Middleware.TypedFn(*Config) = struct {
        fn rate_limit_mw(next: *Middleware.Next, c: *Config) !http.Respond {
            const ip = next.ctx.tls.info().address;
            const time = std.time.milliTimestamp();

            c.mutex.lock();
            const entry = try c.map.getOrPut(ip);

            if (entry.found_existing) {
                entry.value_ptr.replenish(
                    time,
                    c.tokens_per_sec,
                    c.max_tokens,
                );
                if (entry.value_ptr.take()) {
                    c.mutex.unlock();
                    return try next.run();
                }
                c.mutex.unlock();

                return c.response_on_limited;
            }

            entry.value_ptr.* = .{
                .tokens = c.max_tokens,
                .last_refill_ms = time,
            };
            c.mutex.unlock();
            return try next.run();
        }
    }.rate_limit_mw;

    return Middleware.init(config, func).layer();
}

pub const Config = struct {
    map: std.AutoHashMapUnmanaged(u128, Bucket),
    tokens_per_sec: u16,
    max_tokens: u16,
    response_on_limited: http.Response.Fields,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        tokens_per_sec: u16,
        max_tokens: u16,
        response_on_limited: ?http.Respond,
    ) Config {
        const respond = response_on_limited orelse .{
            .status = .@"Too Many Requests",
            .mime = .TEXT,
            .body = "",
        };

        return .{
            .map = .empty,
            .tokens_per_sec = tokens_per_sec,
            .max_tokens = max_tokens,
            .response_on_limited = respond,
        };
    }

    pub fn deinit(config: *Config, gpa: mem.Allocator) void {
        config.map.deinit(gpa);
    }
};

const Bucket = struct {
    tokens: u16,
    last_refill_ms: i64,

    pub fn replenish(
        bucket: *Bucket,
        time_ms: i64,
        tokens_per_sec: u16,
        max_tokens: u16,
    ) void {
        const delta_ms = time_ms - bucket.last_refill_ms;
        const new_tokens: u16 = @intCast(
            @divFloor(delta_ms * tokens_per_sec, std.time.ms_per_s),
        );
        bucket.tokens = @min(max_tokens, bucket.tokens + new_tokens);
        bucket.last_refill_ms = time_ms;
    }

    pub fn take(self: *Bucket) bool {
        if (self.tokens > 0) {
            self.tokens -= 1;
            return true;
        }

        return false;
    }
};

const std = @import("std");
const mem = std.mem;

const zzz = @import("../../root.zig");
const http = zzz.http;
const Router = zzz.http.Router;
const Middleware = Router.Middleware;
