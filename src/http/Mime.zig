/// MIME Types.
pub const Mime = @This();
/// This is the actual MIME type.
content_type: Option,
extension: Option,
description: []const u8,

pub const AAC: Mime = .init(
    &.{"audio/acc"},
    &.{"acc"},
    "AAC Audio",
);
pub const APNG: Mime = .init(
    &.{"image/apng"},
    &.{"apng"},
    "Animated Portable Network Graphics (APNG) Image",
);
pub const AVIF: Mime = .init(
    &.{"image/avif"},
    &.{"avif"},
    "AVIF Image",
);
pub const AVI: Mime = .init(
    &.{"video/x-msvideo"},
    &.{"avi"},
    "AVI: Audio Video Interleave",
);
pub const AZW: Mime = .init(
    &.{"application/vnd.amazon.ebook"},
    &.{"azw"},
    "AZW: Amazon Kindle eBook format",
);
pub const BIN: Mime = .init(
    &.{"application/octet-stream"},
    &.{"bin"},
    "Any kind of binary data",
);
pub const BMP: Mime = .init(
    &.{"image/bmp"},
    &.{"bmp"},
    "Windows OS/2 Bitmap Graphics",
);
pub const BZ: Mime = .init(
    &.{"application/x-bzip"},
    &.{"bz"},
    "BZip archive",
);
pub const BZ2: Mime = .init(
    &.{"application/x-bzip2"},
    &.{"bz2"},
    "BZip2 archive",
);
pub const CDA: Mime = .init(
    &.{"application/x-cdf"},
    &.{"cda"},
    "CD audio",
);
pub const CSS: Mime = .init(
    &.{"text/css"},
    &.{"css"},
    "Cascading Style Sheets (CSS)",
);
pub const CSV: Mime = .init(
    &.{"text/csv"},
    &.{"csv"},
    "Comma-separated values (CSV)",
);
pub const DOC: Mime = .init(
    &.{"application/msword"},
    &.{"doc"},
    "Microsoft Word",
);
pub const DOCX: Mime = .init(
    &.{"application/vnd.openxlformats-officedocument.wordprocessingml.document"},
    &.{"docx"},
    "Microsoft Word (OpenXML)",
);
pub const EPUB: Mime = .init(
    &.{"application/epub+zip"},
    &.{"epub"},
    "Electronic Publication",
);
pub const GIF: Mime = .init(
    &.{"image/gif"},
    &.{"gif"},
    "Graphics Interchange Format (GIF)",
);
pub const GZ: Mime = .init(
    &.{ "application/gzip", "application/x-gzip" },
    &.{"gz"},
    "GZip Compressed Archive",
);
pub const HTML: Mime = .init(
    &.{"text/html"},
    &.{ "html", "htm" },
    "HyperText Markup Language (HTML)",
);
pub const ICO: Mime = .init(
    &.{ "image/x-icon", "image/vnd.microsoft.icon" },
    &.{"ico"},
    "Icon Format",
);
pub const ICS: Mime = .init(
    &.{"text/calander"},
    &.{"ics"},
    "iCalendar format",
);
pub const JAR: Mime = .init(
    &.{"application/java-archive"},
    &.{"jar"},
    "Java Archive",
);
pub const JPEG: Mime = .init(
    &.{"image/jpeg"},
    &.{ "jpeg", "jpg" },
    "JPEG Image",
);
pub const JS: Mime = .init(
    &.{ "text/javascript", "application/javascript" },
    &.{"js"},
    "JavaScript",
);
pub const JSON: Mime = .init(
    &.{"application/json"},
    &.{"json"},
    "JSON Format",
);
pub const MP3: Mime = .init(
    &.{"audio/mpeg"},
    &.{"mp3"},
    "MP3 audio",
);
pub const MP4: Mime = .init(
    &.{"video/mp4"},
    &.{"mp4"},
    "MP4 Video",
);
pub const OGA: Mime = .init(
    &.{"audio/ogg"},
    &.{"ogg"},
    "Ogg audio",
);
pub const OGV: Mime = .init(
    &.{"video/ogg"},
    &.{"ogv"},
    "Ogg video",
);
pub const OGX: Mime = .init(
    &.{"application/ogg"},
    &.{"ogx"},
    "Ogg multiplexed audo and video",
);
pub const OTF: Mime = .init(
    &.{"font/otf"},
    &.{"otf"},
    "OpenType font",
);
pub const PDF: Mime = .init(
    &.{"application/pdf"},
    &.{"pdf"},
    "Adobe Portable Document Format",
);
pub const PHP: Mime = .init(
    &.{"application/x-httpd-php"},
    &.{"php"},
    "Hypertext Preprocessor (Personal Home Page)",
);
pub const PNG: Mime = .init(
    &.{"image/png"},
    &.{"png"},
    "Portable Network Graphics",
);
pub const RAR: Mime = .init(
    &.{"application/vnd.rar"},
    &.{"rar"},
    "RAR archive",
);
pub const RTF: Mime = .init(
    &.{"application/rtf"},
    &.{"rtf"},
    "Rich Text Format (RTF)",
);
pub const SH: Mime = .init(
    &.{"application/x-sh"},
    &.{"sh"},
    "Bourne shell script",
);
pub const SVG: Mime = .init(
    &.{"image/svg+xml"},
    &.{"svg"},
    "Scalable Vector Graphics (SVG)",
);
pub const TAR: Mime = .init(
    &.{"application/x-tar"},
    &.{"tar"},
    "Tape Archive (TAR)",
);
pub const TEXT: Mime = .init(
    &.{"text/plain"},
    &.{"txt"},
    "Text (generally ASCII or ISO-8859-n)",
);
pub const TSV: Mime = .init(
    &.{"text/tab-seperated-values"},
    &.{"tsv"},
    "Tab-seperated values (TSV)",
);
pub const TTF: Mime = .init(
    &.{"font/ttf"},
    &.{"ttf"},
    "TrueType Font",
);
pub const WAV: Mime = .init(
    &.{"audio/wav"},
    &.{"wav"},
    "Waveform Audio Format",
);
pub const WEBA: Mime = .init(
    &.{"audio/webm"},
    &.{"weba"},
    "WEBM Audio",
);
pub const WEBM: Mime = .init(
    &.{"video/webm"},
    &.{"webm"},
    "WEBM Video",
);
pub const WEBP: Mime = .init(
    &.{"image/webp"},
    &.{"webp"},
    "WEBP Image",
);
pub const WOFF: Mime = .init(
    &.{"font/woff"},
    &.{"woff"},
    "Web Open Font Format (WOFF)",
);
pub const WOFF2: Mime = .init(
    &.{"font/woff2"},
    &.{"woff2"},
    "Web Open Font Format (WOFF)",
);
pub const XML: Mime = .init(
    &.{"application/xml"},
    &.{"xml"},
    "XML",
);
pub const ZIP: Mime = .init(
    &.{"application/zip"},
    &.{"zip"},
    "ZIP Archive",
);
pub const @"7Z": Mime = .init(
    &.{"application/x-7z-compressed"},
    &.{"7z"},
    "7-zip archive",
);

pub fn init(
    comptime content_type: []const [:0]const u8,
    comptime extension: []const [:0]const u8,
    description: []const u8,
) Mime {
    return .{
        .content_type = generate_mime_helper(content_type),
        .extension = generate_mime_helper(extension),
        .description = description,
    };
}

pub fn from_extension(extension: []const u8) Mime {
    assert(extension.len > 0);
    return mime_extension_map.get(extension) orelse .BIN;
}

pub fn from_content_type(content_type: []const u8) Mime {
    assert(content_type.len > 0);
    return mime_content_map.get(content_type) orelse .BIN;
}

const Option = union(enum) {
    single: [:0]const u8,
    /// The first one should be the priority one.
    /// The rest should just be there for compatibility reasons.
    multiple: []const [:0]const u8,
};

fn generate_mime_helper(comptime mime: []const [:0]const u8) Option {
    switch (mime.len) {
        else => unreachable,
        1 => return .{ .single = mime[0] },
        2 => return .{ .multiple = mime },
    }
}

const all_mime_types = blk: {
    const decls_names = @typeInfo(Mime).@"struct".decl_names;
    var mimes: [decls_names.len]Mime = undefined;
    var index: usize = 0;
    for (decls_names) |decl| {
        if (@TypeOf(@field(Mime, decl)) == Mime) {
            mimes[index] = @field(Mime, decl);
            index += 1;
        }
    }

    var return_mimes: [index]Mime = undefined;
    for (0..index) |i| {
        return_mimes[i] = mimes[i];
    }

    break :blk return_mimes;
};

const mime_extension_map: std.StaticStringMap(Mime) = blk: {
    const num_pairs = num: {
        var count: usize = 0;
        for (all_mime_types) |mime| {
            var value: usize = 0;
            value += switch (mime.extension) {
                .single => 1,
                .multiple => |items| items.len,
            };
            count += value;
        }

        break :num count;
    };

    var pairs: [num_pairs]core.Pair([]const u8, Mime) = undefined;

    var index: usize = 0;
    for (all_mime_types[0..]) |mime| {
        switch (mime.extension) {
            .single => |inner| {
                defer index += 1;
                pairs[index] = .{ inner, mime };
            },
            .multiple => |extensions| {
                for (extensions) |ext| {
                    defer index += 1;
                    pairs[index] = .{ ext, mime };
                }
            },
        }
    }

    break :blk .initComptime(pairs);
};

const mime_content_map: std.StaticStringMap(Mime) = blk: {
    const num_pairs = num: {
        var count: usize = 0;
        for (all_mime_types) |mime| {
            var value: usize = 0;
            value += switch (mime.content_type) {
                .single => 1,
                .multiple => |items| items.len,
            };
            count += value;
        }

        break :num count;
    };

    var pairs: [num_pairs]core.Pair([]const u8, Mime) = undefined;

    var index: usize = 0;
    for (all_mime_types[0..]) |mime| {
        switch (mime.content_type) {
            .single => |inner| {
                defer index += 1;
                pairs[index] = .{ inner, mime };
            },
            .multiple => |content_types| {
                for (content_types) |ext| {
                    defer index += 1;
                    pairs[index] = .{ ext, mime };
                }
            },
        }
    }

    break :blk .initComptime(pairs);
};

test "MIME from extensions" {
    for (all_mime_types) |mime| {
        switch (mime.extension) {
            .single => |inner| {
                try testing.expectEqualStrings(
                    mime.description,
                    Mime.from_extension(inner).description,
                );
            },
            .multiple => |extensions| {
                for (extensions) |ext| {
                    try testing.expectEqualStrings(
                        mime.description,
                        Mime.from_extension(ext).description,
                    );
                }
            },
        }
    }
}

test "MIME from unknown extension" {
    const extension = ".whatami";
    const mime = Mime.from_extension(extension);
    try testing.expectEqual(Mime.BIN, mime);
}

test "MIME from content types" {
    for (all_mime_types) |mime| {
        switch (mime.content_type) {
            .single => |inner| {
                try testing.expectEqualStrings(
                    mime.description,
                    Mime.from_content_type(inner).description,
                );
            },
            .multiple => |content_types| {
                for (content_types) |ext| {
                    try testing.expectEqualStrings(
                        mime.description,
                        Mime.from_content_type(ext).description,
                    );
                }
            },
        }
    }
}

test "MIME from unknown content type" {
    const content_type = "application/whatami";
    const mime = Mime.from_content_type(content_type);
    try testing.expectEqual(Mime.BIN, mime);
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const zzz = @import("../root.zig");
const core = zzz.core;
