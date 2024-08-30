const std = @import("std");
const log = std.log.scoped(.@"zzz/tls/bearssl");

const Socket = @import("../core/socket.zig").Socket;

const bearssl = @cImport({
    @cInclude("bearssl.h");
});

const PrivateKey = union(enum) {
    RSA: bearssl.br_rsa_private_key,
    EC: bearssl.br_ec_private_key,
};

fn fmt_bearssl_error(error_code: c_int) []const u8 {
    return switch (error_code) {
        bearssl.BR_ERR_OK => "BR_ERR_OK",
        bearssl.BR_ERR_BAD_PARAM => "BR_ERR_BAD_PARAM",
        bearssl.BR_ERR_BAD_STATE => "BR_ERR_BAD_STATE",
        bearssl.BR_ERR_UNSUPPORTED_VERSION => "BR_ERR_UNSUPPORTED_VERSION",
        bearssl.BR_ERR_BAD_VERSION => "BR_ERR_BAD_VERSION",
        bearssl.BR_ERR_TOO_LARGE => "BR_ERR_TOO_LARGE",
        bearssl.BR_ERR_BAD_MAC => "BR_ERR_BAD_MAC",
        bearssl.BR_ERR_NO_RANDOM => "BR_ERR_NO_RANDOM",
        bearssl.BR_ERR_UNKNOWN_TYPE => "BR_ERR_UNKNOWN_TYPE",
        bearssl.BR_ERR_UNEXPECTED => "BR_ERR_UNEXPECTED",
        bearssl.BR_ERR_BAD_CCS => "BR_ERR_BAD_CCS",
        bearssl.BR_ERR_BAD_ALERT => "BR_ERR_BAD_ALERT",
        bearssl.BR_ERR_BAD_HANDSHAKE => "BR_ERR_BAD_HANDSHAKE",
        bearssl.BR_ERR_OVERSIZED_ID => "BR_ERR_OVERSIZED_ID",
        bearssl.BR_ERR_BAD_CIPHER_SUITE => "BR_ERR_BAD_CIPHER_SUITE",
        bearssl.BR_ERR_BAD_COMPRESSION => "BR_ERR_BAD_COMPRESSION",
        bearssl.BR_ERR_BAD_FRAGLEN => "BR_ERR_BAD_FRAGLEN",
        bearssl.BR_ERR_BAD_SECRENEG => "BR_ERR_BAD_SECRENEG",
        bearssl.BR_ERR_EXTRA_EXTENSION => "BR_ERR_EXTRA_EXTENSION",
        bearssl.BR_ERR_BAD_SNI => "BR_ERR_BAD_SNI",
        bearssl.BR_ERR_BAD_HELLO_DONE => "BR_ERR_BAD_HELLO_DONE",
        bearssl.BR_ERR_LIMIT_EXCEEDED => "BR_ERR_LIMIT_EXCEEDED",
        bearssl.BR_ERR_BAD_FINISHED => "BR_ERR_BAD_FINISHED",
        bearssl.BR_ERR_RESUME_MISMATCH => "BR_ERR_RESUME_MISMATCH",
        bearssl.BR_ERR_INVALID_ALGORITHM => "BR_ERR_INVALID_ALGORITHM",
        bearssl.BR_ERR_BAD_SIGNATURE => "BR_ERR_BAD_SIGNATURE",
        bearssl.BR_ERR_WRONG_KEY_USAGE => "BR_ERR_WRONG_KEY_USAGE",
        bearssl.BR_ERR_NO_CLIENT_AUTH => "BR_ERR_NO_CLIENT_AUTH",
        bearssl.BR_ERR_IO => "BR_ERR_IO",
        bearssl.BR_ERR_RECV_FATAL_ALERT => "BR_ERR_RECV_FATAL_ALERT",
        bearssl.BR_ERR_SEND_FATAL_ALERT => "BR_ERR_SEND_FATAL_ALERT",
        else => "Unknown BearSSL Error",
    };
}

fn parse_pem(allocator: std.mem.Allocator, section: []const u8, buffer: []const u8) ![]const u8 {
    var p_ctx: bearssl.br_pem_decoder_context = undefined;
    bearssl.br_pem_decoder_init(&p_ctx);

    var decoded = std.ArrayList(u8).init(allocator);

    bearssl.br_pem_decoder_setdest(&p_ctx, struct {
        fn decoder_cb(ctx: ?*anyopaque, src: ?*const anyopaque, size: usize) callconv(.C) void {
            var list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
            const src_buffer: [*c]const u8 = @ptrCast(src.?);
            list.appendSlice(src_buffer[0..size]) catch unreachable;
        }
    }.decoder_cb, &decoded);

    var found = false;
    var written: usize = 0;
    while (written < buffer.len) {
        written += bearssl.br_pem_decoder_push(&p_ctx, buffer[written..].ptr, buffer.len - written);
        const event = bearssl.br_pem_decoder_event(&p_ctx);
        switch (event) {
            0, bearssl.BR_PEM_BEGIN_OBJ => {
                const name = bearssl.br_pem_decoder_name(&p_ctx);
                log.debug("Name: {s}", .{std.mem.span(name)});
                if (std.mem.eql(u8, std.mem.span(name), section)) {
                    found = true;
                    decoded.clearRetainingCapacity();
                }
            },
            bearssl.BR_PEM_END_OBJ => {
                if (found) {
                    return decoded.toOwnedSlice();
                }
            },
            bearssl.BR_PEM_ERROR => return error.PEMDecodeFailed,
            else => return error.PEMDecodeUnknownEvent,
        }
    }

    return error.PrivateKeyNotFound;
}

const TLSContextOptions = struct {
    allocator: std.mem.Allocator,
    cert_path: []const u8,
    key_path: []const u8,
    cert_name: []const u8,
    key_name: []const u8,
    size_tls_buffer_max: u32,
};

pub const TLSContext = struct {
    allocator: std.mem.Allocator,
    x509: *bearssl.br_x509_certificate,
    pkey: PrivateKey,
    cert: []const u8,
    key: []const u8,

    /// This only needs to be called once and it should create all of the stuff needed.
    pub fn init(options: TLSContextOptions) !TLSContext {
        var self: TLSContext = undefined;
        self.allocator = options.allocator;

        // Read Certificate.
        const cert_buf = try std.fs.cwd().readFileAlloc(
            self.allocator,
            options.cert_path,
            1024 * 1024,
        );
        defer self.allocator.free(cert_buf);

        const key_buf = try std.fs.cwd().readFileAlloc(
            self.allocator,
            options.key_path,
            1024 * 1024,
        );
        defer self.allocator.free(key_buf);

        self.cert = try parse_pem(self.allocator, options.cert_name, cert_buf);

        var x_ctx: bearssl.br_x509_decoder_context = undefined;
        bearssl.br_x509_decoder_init(&x_ctx, null, null);
        bearssl.br_x509_decoder_push(&x_ctx, self.cert.ptr, self.cert.len);

        if (bearssl.br_x509_decoder_last_error(&x_ctx) != 0) {
            return error.CertificateDecodeFailed;
        }

        self.x509 = try options.allocator.create(bearssl.br_x509_certificate);
        self.x509.* = bearssl.br_x509_certificate{
            .data = @constCast(self.cert.ptr),
            .data_len = self.cert.len,
        };

        // Read Private Key.
        self.key = try parse_pem(self.allocator, options.key_name, key_buf);

        var sk_ctx: bearssl.br_skey_decoder_context = undefined;
        bearssl.br_skey_decoder_init(&sk_ctx);
        bearssl.br_skey_decoder_push(&sk_ctx, self.key.ptr, self.key.len);

        if (bearssl.br_skey_decoder_last_error(&sk_ctx) != 0) {
            return error.PrivateKeyDecodeFailed;
        }

        const key_type = bearssl.br_skey_decoder_key_type(&sk_ctx);

        switch (key_type) {
            bearssl.BR_KEYTYPE_RSA => {
                self.pkey = .{ .RSA = bearssl.br_skey_decoder_get_rsa(&sk_ctx)[0] };
            },
            bearssl.BR_KEYTYPE_EC => {
                self.pkey = .{ .EC = bearssl.br_skey_decoder_get_ec(&sk_ctx)[0] };
                log.debug("Key Curve Type: {d}", .{self.pkey.EC.curve});
            },
            else => {
                return error.InvalidKeyType;
            },
        }

        return self;
    }

    pub fn create(self: TLSContext, socket: Socket) !TLS {
        var tls = TLS.init(.{
            .allocator = self.allocator,
            .socket = socket,
            .context = undefined,
            .pkey = self.pkey,
            .chain = self.x509[0..1],
        });

        switch (self.pkey) {
            .RSA => |*inner| {
                bearssl.br_ssl_server_init_full_rsa(
                    &tls.context,
                    self.x509,
                    1,
                    inner,
                );
            },
            .EC => |*inner| {
                bearssl.br_ssl_server_init_full_ec(
                    &tls.context,
                    self.x509,
                    1,
                    bearssl.BR_KEYTYPE_EC,
                    inner,
                );
            },
        }

        if (bearssl.br_ssl_engine_last_error(&tls.context.eng) != 0) {
            return error.ServerInitializationFailed;
        }

        return tls;
    }

    pub fn deinit(self: TLSContext) void {
        self.allocator.free(self.cert);
        self.allocator.free(self.key);
        self.allocator.destroy(self.x509);
    }
};

const PolicyContext = struct {
    vtable: *bearssl.br_ssl_server_policy_class,
    id: u32 = 0,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
};

fn choose(
    pctx: [*c][*c]const bearssl.br_ssl_server_policy_class,
    ctx: [*c]const bearssl.br_ssl_server_context,
    choices: [*c]bearssl.br_ssl_server_choices,
) callconv(.C) c_int {
    // https://www.bearssl.org/apidoc/structbr__ssl__server__policy__class__.html
    const policy: *const PolicyContext = @ptrCast(@alignCast(pctx));
    log.debug("Choose fired! | ID: {d}", .{policy.id});
    _ = ctx;

    choices.*.chain = policy.chain.ptr;
    choices.*.chain_len = policy.chain.len;
    choices.*.cipher_suite = bearssl.BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256;
    choices.*.algo_id = bearssl.br_sha256_ID;
    return 1;
}

fn do_keyx(
    pctx: [*c][*c]const bearssl.br_ssl_server_policy_class,
    data: [*c]u8,
    len: [*c]usize,
) callconv(.C) u32 {
    const policy: *const PolicyContext = @ptrCast(@alignCast(pctx));
    log.debug("KeyX fired! | ID: {d}", .{policy.id});
    _ = data;
    _ = len;

    return 0;
}

fn do_sign(
    pctx: [*c][*c]const bearssl.br_ssl_server_policy_class,
    algo_id: c_uint,
    data: [*c]u8,
    hv_len: usize,
    len: usize,
) callconv(.C) usize {
    const policy: *const PolicyContext = @ptrCast(@alignCast(pctx));
    log.debug("Sign fired! | ID: {d}", .{policy.id});
    _ = algo_id;
    _ = data;
    _ = hv_len;
    _ = len;

    return 0;
}

const TLSOptions = struct {
    allocator: std.mem.Allocator,
    socket: Socket,
    context: bearssl.br_ssl_server_context,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
};

pub const TLS = struct {
    allocator: std.mem.Allocator,
    socket: Socket,
    context: bearssl.br_ssl_server_context,
    iobuf: []u8,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
    policy: *PolicyContext = undefined,

    pub fn init(options: TLSOptions) TLS {
        return .{
            .allocator = options.allocator,
            .socket = options.socket,
            .context = options.context,
            .iobuf = options.allocator.alloc(u8, bearssl.BR_SSL_BUFSIZE_BIDI) catch unreachable,
            .chain = options.chain,
            .pkey = options.pkey,
            .policy = options.allocator.create(PolicyContext) catch unreachable,
        };
    }

    pub fn deinit(self: TLS) void {
        self.allocator.free(self.iobuf);
        self.allocator.free(self.chain);

        self.allocator.destroy(self.policy.vtable);
        self.allocator.destroy(self.policy);
    }

    pub fn accept(self: *TLS) !void {
        const engine = &self.context.eng;
        bearssl.br_ssl_engine_set_buffer(engine, self.iobuf.ptr, self.iobuf.len, 1);

        // Build the Policy.
        self.policy.vtable = try self.allocator.create(bearssl.br_ssl_server_policy_class);
        self.policy.vtable.* = bearssl.br_ssl_server_policy_class{
            .context_size = @sizeOf(PolicyContext),
            .choose = choose,
            .do_keyx = do_keyx,
            .do_sign = do_sign,
        };
        self.policy.chain = self.chain;
        self.policy.pkey = self.pkey;
        self.policy.id = 100;

        bearssl.br_ssl_server_set_policy(&self.context, @ptrCast(&self.policy.vtable));

        const reset_status = bearssl.br_ssl_server_reset(&self.context);
        if (reset_status < 0) {
            return error.ServerResetFailed;
        }

        var cycle_count: u32 = 0;
        while (cycle_count < 20) {
            const last_error = bearssl.br_ssl_engine_last_error(engine);
            log.debug("Cycle {d} - Last Error | {d}", .{ cycle_count, last_error });
            if (last_error != 0) {
                log.debug("Cycle {d} - Handshake Failed | {s}", .{
                    cycle_count,
                    fmt_bearssl_error(last_error),
                });
                return error.HandshakeFailed;
            }

            cycle_count += 1;
            const state = bearssl.br_ssl_engine_current_state(engine);
            log.debug("Cycle {d} - Engine State | {any}", .{ cycle_count, state });

            if ((state & bearssl.BR_SSL_CLOSED) != 0) {
                return error.HandshakeFailed;
            }

            if ((state & bearssl.BR_SSL_SENDREC) != 0) {
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_sendrec_buf(engine, &length);
                log.debug("Cycle {d} - Send Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }
                var total_sent: usize = 0;
                while (total_sent < length) {
                    const sent = try std.posix.send(self.socket, buf[total_sent..length], 0);
                    total_sent += sent;
                }
                bearssl.br_ssl_engine_sendrec_ack(engine, total_sent);
                bearssl.br_ssl_engine_flush(engine, 0);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVREC) != 0) {
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                log.debug("Cycle {d} - Recv Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }
                var total_read: usize = 0;
                while (total_read < length) {
                    const read = try std.posix.recv(self.socket, buf[total_read..length], 0);
                    total_read += read;
                    log.debug("Cycle {d} - Total Read: {d}", .{ cycle_count, total_read });
                }

                bearssl.br_ssl_engine_recvrec_ack(engine, total_read);
                continue;
            }

            if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
                log.debug("Cycle {d} - Handshake Complete!", .{cycle_count});
                return;
            }

            if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
                return error.UnexpectedState;
            }
        }

        return error.HandshakeTimeout;
    }

    pub fn decrypt(self: *TLS, encrypted: []const u8) ![]const u8 {
        _ = self;
        _ = encrypted;
        @panic("TODO DECRYPTION");
        //const engine = &self.context.eng;

        //// Push the encrypted data.
        //const buffer = bearssl.br_ssl_engine_sendrec_buf(engine, encrypted.len)[0..encrypted.len];
        //std.mem.copyForwards(u8, buffer, encrypted);
        //bearssl.br_ssl_engine_sendrec_ack(engine, encrypted.len);

        //// Read out the plaintext data.
        //const unencrypted = bearssl.br_ssl_engine_recvapp_buf(engine, encrypted.len)[0..encrypted.len];
        //return unencrypted;
    }

    pub fn encrypt(self: *TLS, plaintext: []const u8) ![]const u8 {
        _ = self;
        _ = plaintext;
        @panic("TODO ENCRYPTION");
        //const engine = &self.context.eng;
        //var encrypted = std.ArrayList(u8).init(self.allocator);
        //defer encrypted.deinit();

        //var total_written: usize = 0;
        //const send_rec_state = bearssl.br_ssl_engine_current_state(engine) == bearssl.BR_SSL_SENDREC;
        //while (total_written < plaintext.len or send_rec_state) {
        //    switch (bearssl.br_ssl_engine_current_state(engine)) {
        //        bearssl.BR_SSL_CLOSED => return error.EngineClosed,
        //        bearssl.BR_SSL_SENDAPP => {
        //            var length: usize = undefined;
        //            const rec_buf = bearssl.br_ssl_engine_sendapp_buf(engine, &length);
        //            if (length == 0) {
        //                continue; // Buffer not ready, try again
        //            }
        //            const to_write = @min(length, plaintext.len - total_written);
        //            std.mem.copyForwards(
        //                u8,
        //                rec_buf[0..to_write],
        //                plaintext[total_written .. total_written + to_write],
        //            );
        //            bearssl.br_ssl_engine_sendapp_ack(engine, to_write);
        //            total_written += to_write;
        //        },
        //        bearssl.BR_SSL_SENDREC => {
        //            var length: usize = undefined;
        //            const encrypted_buf = bearssl.br_ssl_engine_sendrec_buf(engine, &length);
        //            if (length == 0) {
        //                continue; // Buffer not ready, try again
        //            }
        //            try encrypted.appendSlice(encrypted_buf[0..length]);
        //            bearssl.br_ssl_engine_sendrec_ack(engine, length);
        //        },
        //        bearssl.BR_SSL_RECVAPP => return error.UnexpectedRecvApp,
        //        bearssl.BR_SSL_RECVREC => {
        //            var length: usize = undefined;
        //            _ = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
        //            if (length > 0) {
        //                bearssl.br_ssl_engine_recvrec_ack(engine, 0);
        //            } else {
        //                _ = bearssl.br_ssl_engine_flush(engine, 0);
        //            }
        //        },
        //        else => return error.UnexpectedState,
        //    }
        //}

        //return encrypted.toOwnedSlice();
    }
};

const testing = std.testing;

test "Parsing Certificates" {
    const cert = "src/examples/tls/certs/server.cert";
    const key = "src/examples/tls/certs/server.key";

    const context = try TLSContext.init(testing.allocator, cert, key);
    defer context.deinit();

    const tls = try context.create();
    defer tls.deinit();
}
