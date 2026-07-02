
// https://github.com/221V/zig_erl_bert  for BERT encode-decode

const std = @import("std");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const BigInt = std.math.big.int.Managed;
const Limb = std.math.big.Limb;
const Endian = std.builtin.Endian;

const assert = std.debug.assert;


pub const Value_Tag = enum(u8){
  int,
  big_int,
  float,
  atom,
  binary,
  tuple,
  list,
  map,
  @"null",
};


const Map_Pair = struct{
  key: Bert_Value,
  val: Bert_Value,
};

pub const Bert_Value = union(Value_Tag){
  int: i64,
  big_int: BigInt,
  float: f64,
  atom: []const u8,
  binary: []const u8,
  tuple: []Bert_Value,
  list: []Bert_Value,
  map: []Map_Pair,
  @"null": void,
};


fn readExact(reader: anytype, buf: []u8) !void{
  var offset: usize = 0;
  while(offset < buf.len){
    const n = try reader.read(buf[offset..]);
    if(n == 0){ return error.EndOfStream; }
    offset += n;
  }
}


pub const Bert = struct{
  const Self = @This();
  allocator: Allocator,
  
  pub fn init(allocator: Allocator) Self{
    return .{ .allocator = allocator };
  }
  
  pub fn deinit(_: *Self) void{ }
  
  // constructors
  pub fn int(self: Self, n: i64) Bert_Value{
    _ = self;
    return .{ .int = n };
  }
  
  pub fn bigInt(self: Self, n: BigInt) Bert_Value{
    _ = self;
    return .{ .big_int = n };
  }
  
  pub fn float(self: Self, f: f64) Bert_Value{
    _ = self;
    return .{ .float = f };
  }
  
  pub fn atom(self: Self, s: []const u8) !Bert_Value{
    const copy = try self.allocator.dupe(u8, s);
    return .{ .atom = copy };
  }
  
  pub fn binary(self: Self, data: []const u8) !Bert_Value{
    const copy = try self.allocator.dupe(u8, data);
    return .{ .binary = copy };
  }
  
  pub fn tuple(self: Self, elems: []const Bert_Value) !Bert_Value{
    const copy = try self.allocator.dupe(Bert_Value, elems);
    return .{ .tuple = copy };
  }
  
  pub fn list(self: Self, elems: []const Bert_Value) !Bert_Value{
    const copy = try self.allocator.dupe(Bert_Value, elems);
    return .{ .list = copy };
  }
  
  pub fn map(self: Self, pairs: []const Map_Pair) !Bert_Value{
    const copy = try self.allocator.dupe(Map_Pair, pairs);
    return .{ .map = copy };
  }
  
  pub fn @"null"(self: Self) Bert_Value{
    _ = self;
    return .{ .@"null" = {} };
  }
  
  // encode
  pub fn encode(self: Self, term: Bert_Value) ![]u8{
    var buffer = ArrayList(u8).init(self.allocator);
    defer buffer.deinit();
    
    try buffer.append(131); // VERSION_MAGIC
    try encodeValue(self.allocator, &buffer, term);
    
    return buffer.toOwnedSlice();
  }
  
  // decode
  pub fn decode(self: Self, data: []const u8) !Bert_Value{
    if(data.len == 0 or data[0] != 131){
      return error.InvalidVersion;
    }
    var stream = std.io.fixedBufferStream(data[1..]);
    return decodeValue(self.allocator, stream.reader());
  }
};


// helpers
fn encodeValue(allocator: Allocator, buffer: *ArrayList(u8), value: Bert_Value) !void{
  switch(value){
    .int => |n|{
      if(n >= 0 and n <= 255){
        try buffer.append(97); // SMALL_INTEGER_EXT
        try buffer.append( @as(u8, @intCast(n)) );
      }else if(n >= -2_147_483_648 and n <= 2_147_483_647){
        try buffer.append(98); // INTEGER_EXT
        const be = @byteSwap( @as(i32, @intCast(n)) );
        try buffer.appendSlice(std.mem.asBytes(&be));
      }else{
        try encodeBigInt(allocator, buffer, n, false);
      }
    },
    
    .big_int => |bi|{
      if( bi.eqlZero() ){ // encode zero as SMALL_BIG_EXT: [110, 1, 0, 0]
        try buffer.append(110);
        try buffer.append(1);
        try buffer.append(0);
        try buffer.append(0);
        return;
      }
      
      const is_neg = !bi.isPositive();
      var abs_bi = try BigInt.init(allocator);
      defer abs_bi.deinit();
      try abs_bi.copy( bi.toConst() );
      if(is_neg){
        abs_bi.negate();
      }
      
      try encodeBigIntFromAbs(allocator, buffer, &abs_bi, is_neg);
    },
    
    .float => |f|{
      try buffer.append(70); // NEW_FLOAT_EXT
      const bits = @as(u64, @bitCast(f));
      var buf: [8]u8 = undefined;
      std.mem.writeInt(u64, &buf, bits, .big);
      try buffer.appendSlice(&buf);
    },
    
    .atom => |s|{
      if(s.len > 65535){ return error.AtomTooLong; }
      try buffer.append(118); // ATOM_UTF8_EXT
      const len_be = @byteSwap( @as(u16, @intCast( @as(u16, @intCast(s.len)) )) );
      try buffer.appendSlice(std.mem.asBytes(&len_be));
      try buffer.appendSlice(s);
    },
    
    .binary => |b|{
      if(b.len > std.math.maxInt(u32)){ return error.BinaryTooLong; }
      try buffer.append(109); // BINARY_EXT
      const len_be = @byteSwap( @as(u32, @intCast(b.len)) );
      try buffer.appendSlice(std.mem.asBytes(&len_be));
      try buffer.appendSlice(b);
    },
    
    .tuple => |elems|{
      if(elems.len <= 255){
        try buffer.append(104); // SMALL_TUPLE_EXT
        try buffer.append( @as(u8, @intCast(elems.len)) );
      }else{
        try buffer.append(105); // LARGE_TUPLE_EXT
        const len_be = @byteSwap( @as(u32, @intCast(elems.len)) );
        try buffer.appendSlice(std.mem.asBytes(&len_be));
      }
      for(elems) |elem|{
        try encodeValue(allocator, buffer, elem);
      }
    },
    
    .list => |elems|{
      try buffer.append(108); // LIST_EXT
      const len_be = @byteSwap( @as(u32, @intCast(elems.len)) );
      try buffer.appendSlice(std.mem.asBytes(&len_be));
      for(elems) |elem|{
        try encodeValue(allocator, buffer, elem);
      }
      try buffer.append(106); // NIL_EXT
    },
    
    .map => |pairs|{
      if(pairs.len > std.math.maxInt(u32)){ return error.MapTooLarge; }
      try buffer.append(116); // MAP_EXT
      const len_be = @byteSwap( @as(u32, @intCast(pairs.len)) );
      try buffer.appendSlice(std.mem.asBytes(&len_be));
      for(pairs) |pair|{
        try encodeValue(allocator, buffer, pair.key);
        try encodeValue(allocator, buffer, pair.val);
      }
    },
    
    .@"null" => {
      try buffer.append(106); // NIL_EXT
    },
  }
}


fn encodeBigInt(allocator: Allocator, buffer: *ArrayList(u8), n: i64, is_neg: bool) !void{
  var abs_n: u64 = if(is_neg) @as(u64, @intCast(-n)) else @as(u64, @intCast(n));
  var digits = std.ArrayList(u8).init(allocator);
  defer digits.deinit();
  
  if(abs_n == 0){
    try digits.append(0);
  }else{
    while(abs_n > 0) : (abs_n >>= 8){
      try digits.append( @as(u8, @intCast(abs_n & 0xFF)) );
    }
  }
  
  const len = digits.items.len;
  if(len > 255){ return error.BigIntTooLargeForSmallBig; }
  
  try buffer.append(110); // SMALL_BIG_EXT
  try buffer.append( @as(u8, @intCast(len)) );
  try buffer.append(if (is_neg) 1 else 0);
  try buffer.appendSlice(digits.items);
}


fn encodeBigIntFromAbs(allocator: Allocator, buffer: *ArrayList(u8), abs_bi: *const BigInt, is_neg: bool) !void{ // abs_bi > 0
  var digits = std.ArrayList(u8).init(allocator);
  defer digits.deinit();
  
  for( abs_bi.limbs[0..abs_bi.len()] ) |limb|{
    var val = limb;
    var i: usize = 0;
    while(i < @sizeOf(Limb)) : (i += 1){
      try digits.append( @as(u8, @truncate(val)) );
      val >>= 8;
    }
  }
  
  while(digits.items.len > 1 and digits.items[digits.items.len - 1] == 0){
    _ = digits.pop();
  }
  
  const len = digits.items.len;
  if(len > 255){ return error.BigIntTooLargeForSmallBig; }
  
  try buffer.append(110); // SMALL_BIG_EXT
  try buffer.append( @as(u8, @intCast(len)) );
  try buffer.append( if(is_neg) 1 else 0 );
  try buffer.appendSlice(digits.items);
}


fn decodeValue(allocator: Allocator, reader: anytype) !Bert_Value{
  const tag = try reader.readByte();
  //std.debug.print("tag: {}\n", .{tag}); // debug
  switch(tag){
    97 => { // SMALL_INTEGER_EXT
      const b = try reader.readByte();
      return Bert_Value{ .int = b };
    },
    
    98 => { // INTEGER_EXT
      var buf: [4]u8 = undefined;
      try readExact(reader, &buf);
      const n = std.mem.readInt(i32, &buf, .big);
      return Bert_Value{ .int = n };
    },
    
    70 => { // NEW_FLOAT_EXT
      var buf: [8]u8 = undefined;
      try readExact(reader, &buf);
      const bits = std.mem.readInt(u64, &buf, .big);
      return Bert_Value{ .float = @as(f64, @bitCast(bits)) };
    },
    
    118 => { // ATOM_UTF8_EXT
      var len_buf: [2]u8 = undefined;
      try readExact(reader, &len_buf);
      const len = std.mem.readInt(u16, &len_buf, .big);
      const atom = try allocator.alloc(u8, len);
      errdefer allocator.free(atom);
      try readExact(reader, atom);
      return Bert_Value{ .atom = atom };
    },
    
    107 => { // STRING_EXT
      var len_buf: [2]u8 = undefined;
      try readExact(reader, &len_buf);
      const len = std.mem.readInt(u16, &len_buf, .big);
      const str = try allocator.alloc(u8, len);
      errdefer allocator.free(str);
      try readExact(reader, str);
      return Bert_Value{ .binary = str };
    },
    
    109 => { // BINARY_EXT
      var len_buf: [4]u8 = undefined;
      try readExact(reader, &len_buf);
      const len = std.mem.readInt(u32, &len_buf, .big);
      const bin = try allocator.alloc(u8, len);
      errdefer allocator.free(bin);
      try readExact(reader, bin);
      return Bert_Value{ .binary = bin };
    },
    
    104, 105 => { // SMALL_TUPLE_EXT, LARGE_TUPLE_EXT
      const arity: u32 = if(tag == 104) try reader.readByte() else blk: {
        var len_buf: [4]u8 = undefined;
        try readExact(reader, &len_buf);
        break :blk std.mem.readInt(u32, &len_buf, .big);
      };
      const elems = try allocator.alloc(Bert_Value, arity);
      for(elems) |*elem|{
        elem.* = try decodeValue(allocator, reader);
      }
      return Bert_Value{ .tuple = elems };
    },
    
    108 => { // LIST_EXT
      var len_buf: [4]u8 = undefined;
      try readExact(reader, &len_buf);
      const len = std.mem.readInt(u32, &len_buf, .big);
      const elems = try allocator.alloc(Bert_Value, len);
      errdefer allocator.free(elems);
      for(elems) |*elem|{
      //for(elems, 0..) |*elem, i|{
        //std.debug.print("lets Decode list element {}: {any}\n", .{i, elem}); // debug
        elem.* = try decodeValue(allocator, reader);
        //std.debug.print("Decoded list element {}: {any}\n", .{i, elem}); // debug
      }
      const tail_tag = try reader.readByte();
      if(tail_tag != 106){ return error.ImproperListNotSupported; }
      return Bert_Value{ .list = elems };
    },
    
    106 => { // NIL_EXT
      return Bert_Value{ .@"null" = {} };
    },
    
    110 => { // SMALL_BIG_EXT
      const n = try reader.readByte();
      const sign = try reader.readByte();
      const is_neg = sign != 0;
      
      if(n == 0){
        return Bert_Value{ .int = 0 };
      }
      
      if(n <= 8){
        var value: u64 = 0;
        var shift: u6 = 0;
        for(0..n) |_|{
          const byte = try reader.readByte();
          value |= @as(u64, byte) << @as(u6, shift);
          shift += 8;
        }
        
        if(is_neg){
          return Bert_Value{ .int = - @as(i64, @intCast(value)) };
        }else if(value <= @as(u64, @intCast(std.math.maxInt(i64))) ){
          return Bert_Value{ .int = @as(i64, @intCast(value)) };
        }
      }
      
      var bi = try BigInt.init(allocator);
      errdefer bi.deinit();
      
      var base = try BigInt.initSet(allocator, 256);
      defer base.deinit();
      var zero = try BigInt.initSet(allocator, 0);
      defer zero.deinit();
      
      try bi.set(0);
      var power = try BigInt.initSet(allocator, 1);
      defer power.deinit();
      
      for(0..n) |_|{
        const byte = try reader.readByte();
        var digit = try BigInt.initSet(allocator, byte);
        defer digit.deinit();
        var term = try BigInt.init(allocator);
        defer term.deinit();
        try term.mul(&digit, &power);
        try bi.add(&bi, &term);
        var next_power = try BigInt.init(allocator);
        defer next_power.deinit();
        try next_power.mul(&power, &base);
        power.deinit();
        power = next_power;
      }
      
      if(is_neg){
        bi.negate();
      }
      
      return Bert_Value{ .big_int = bi };
    },
    
    116 => { // MAP_EXT
      var len_buf: [4]u8 = undefined;
      try readExact(reader, &len_buf);
      const len = std.mem.readInt(u32, &len_buf, .big);
      const pairs = try allocator.alloc(Map_Pair, len);
      for(pairs) |*pair|{
        pair.key = try decodeValue(allocator, reader);
        pair.val = try decodeValue(allocator, reader);
      }
      return Bert_Value{ .map = pairs };
    },
    
    else => return error.UnsupportedTag,
  }
}


// next for matching - select values from decoded with try, without shitcode (if(..){..}else if(..){..})

pub const Bert_Get_Error = error{
  Not_List,
  Not_Tuple,
  Not_Map,
  Not_Atom,
  Not_Binary,
  Not_Int,
  Not_Big_Int,
  Not_Float,
  Not_Found,
  Index_Out_Of_Range,
  Value_Out_Of_Range,
  Big_Int_Too_Large, // bigger than max u128 = 340282366920938463463374607431768211455
};


pub fn get_int_as_u8(val: Bert_Value) Bert_Get_Error!u8{
  return switch(val){
    .int => |i|{
      if(i < 0 or i > std.math.maxInt(u8)){ return error.Value_Out_Of_Range; }
      return @as(u8, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_int_as_u16(val: Bert_Value) Bert_Get_Error!u16{
  return switch(val){
    .int => |i|{
      if(i < 0 or i > std.math.maxInt(u16)){ return error.Value_Out_Of_Range; }
      return @as(u16, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_int_as_u32(val: Bert_Value) Bert_Get_Error!u32{
  return switch(val){
    .int => |i|{
      if(i < 0 or i > std.math.maxInt(u32)){ return error.Value_Out_Of_Range; }
      return @as(u32, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_int_as_u64(val: Bert_Value) Bert_Get_Error!u64{
  return switch(val){
    .int => |i|{
      if(i < 0){ return error.Value_Out_Of_Range; } // 0 - 18446744073709551615
      return @as(u64, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_big_int_as_u128(val: Bert_Value) Bert_Get_Error!u128{
  const bi = switch(val){
    .big_int => |b| b,
    else => return error.Not_Big_Int,
  };
  
  if(!bi.isPositive()){ return error.Value_Out_Of_Range; } // negative value
  
  const limb_cnt = bi.len(); // limbs count (0..2) // each limb is little‑endian u64, 2 pcs for u128 needs
  if(limb_cnt == 0){ return @as(u128, 0); }
  if(limb_cnt > 2){ return error.Big_Int_Too_Large; } // bigger than max u128
  
  const low  = @as(u128, @intCast(bi.limbs[0]));
  var result = low;
  
  if(limb_cnt == 2){
    const high = @as(u128, @intCast(bi.limbs[1]));
    result = (high << 64) | low; // shift and concatenate
  }
  
  return result;
}


pub fn get_int_as_i8(val: Bert_Value) Bert_Get_Error!i8{
  return switch(val){
    .int => |i|{
      if(i < std.math.minInt(i8) or i > std.math.maxInt(i8)){ return error.Value_Out_Of_Range; }
      return @as(i8, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_int_as_i16(val: Bert_Value) Bert_Get_Error!i16{
  return switch(val){
    .int => |i|{
      if(i < std.math.minInt(i16) or i > std.math.maxInt(i16)){ return error.Value_Out_Of_Range; }
      return @as(i16, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_int_as_i32(val: Bert_Value) Bert_Get_Error!i32{
  return switch(val){
    .int => |i|{
      if(i < std.math.minInt(i32) or i > std.math.maxInt(i32)){ return error.Value_Out_Of_Range; }
      return @as(i32, @intCast(i));
    },
    else => error.Not_Int,
  };
}


pub fn get_int_as_i64(val: Bert_Value) Bert_Get_Error!i64{
  return switch(val){
    .int => |i| i, // i64
    else => error.Not_Int,
  };
}


pub fn get_float_as_f64(val: Bert_Value) Bert_Get_Error!f64{
  return switch(val){
    .float => |f| f, // f64
    else => error.Not_Float,
  };
}


pub fn get_atom_as_str(val: Bert_Value) Bert_Get_Error![]const u8{
  return switch(val){
    .atom => |at| at, // []const u8
    else => error.Not_Atom,
  };
}


pub fn get_binary_as_str(val: Bert_Value) Bert_Get_Error![]const u8{
  return switch(val){
    .binary => |bin| bin, // []const u8
    else => error.Not_Binary,
  };
}


pub fn get_list_elem(val: Bert_Value, idx: u32) Bert_Get_Error!Bert_Value{ // get elem from list
  return switch(val){
    .list => |elems|{
      if(idx >= elems.len){ return error.Index_Out; }
        return elems[idx];
      },
    else => error.Not_List,
  };
}


pub fn get_tuple_elem(val: Bert_Value, idx: u32) Bert_Get_Error!Bert_Value{ // get elem from tuple
  return switch(val){
    .tuple => |elems|{
      if(idx >= elems.len){ return error.Index_Out_Of_Range; }
        return elems[idx];
      },
    else => error.Not_Tuple,
  };
}


pub fn get_list(val: Bert_Value) Bert_Get_Error![]Bert_Value{ // get list
  return switch(val){
    .list => |elems| elems,
    else => error.Not_List,
  };
}


pub fn get_tuple(val: Bert_Value) Bert_Get_Error![]Bert_Value{ // get tuple
  return switch(val){
    .tuple => |elems| elems,
    else => error.Not_Tuple,
  };
}


pub fn map_lookup(val: Bert_Value, key: Bert_Value) Bert_Get_Error!Bert_Value{
  return switch(val){
    .map => |pairs|{
      for(pairs) |pair|{
        if(std.meta.eql(pair.key, key)){ return pair.val; } // compare type and value
      }
      return error.Not_Found;
    },
    else => error.Not_Map,
  };
}


// next for pretty print in erlang style

pub fn format_bert(allocator: Allocator, value: Bert_Value) ![]const u8{
  var out = std.ArrayList(u8).init(allocator);
  defer out.deinit();
  
  try writeValue(&out, value);
  return out.toOwnedSlice();
}


fn writeValue(buf: *std.ArrayList(u8), value: Bert_Value) !void{
  const writer = buf.writer();
  switch(value){
    .int => |i|{
      try writer.print("{}", .{i});
    },
    
    .big_int => |bi|{ // BigInt to decimal string
      const s = try bi.toString(buf.allocator, 10, .lower);
      defer buf.allocator.free(s);
      try writer.print("{any}", .{s});
    },
    
    .float => |f|{
      try writer.print("{any}", .{f});
    },
    
    .atom => |a|{
      const needQuotes = !isSimpleAtom(a); // simple atoms (ascii, digits and _ symbol, begins from ascii symbol)
      if(needQuotes) try writer.print("'{s}'", .{a}) else try writer.print("{s}", .{a});
    },
    
    .binary => |b|{
      if(std.unicode.utf8ValidateSlice(b)){ // as text when ascii/utf8, otherwise bytes
        try writer.print("<<\"{s}\">>", .{b});
      }else{
        try writer.print("<<", .{});
        for(b, 0..) |byte, i|{
          if(i != 0){ try writer.print(",", .{}); }
          try writer.print("{}", .{byte});
        }
        try writer.print(">>", .{});
      }
    },
    
    .tuple => |elems|{
      try writer.print("{{", .{});
      for(elems, 0..) |e, i|{
        if(i != 0){ try writer.print(", ", .{}); }
        try writeValue(buf, e);
      }
      try writer.print("}}", .{});
    },
    
    .list => |elems|{
      try writer.print("[", .{});
      for(elems, 0..) |e, i|{
        if(i != 0){ try writer.print(", ", .{}); }
        try writeValue(buf, e);
      }
      try writer.print("]", .{});
    },
    
    .map => |pairs|{
      try writer.print("#{{", .{});
      for(pairs, 0..) |p, i|{
        if(i != 0){ try writer.print(", ", .{}); }
        try writeValue(buf, p.key);
        try writer.print(" => ", .{});
        try writeValue(buf, p.val);
      }
      try writer.print("}}", .{});
    },
    
    .@"null" => { // NIL is empty list in BERT
      try writer.print("[]", .{});
    },
  }
}


fn isSimpleAtom(a: []const u8) bool{
  if(a.len == 0){ return false; }
  if(std.ascii.isDigit(a[0])){ return false; } // first symbol can not be digit
  for(a) |c|{
    if(!std.ascii.isAlphanumeric(c) and c != '_'){ return false; }
  }
  return true;
}


fn isPrintableAscii(b: []const u8) bool{
  for(b) |c|{
    if(c < 32 or c > 126){ return false; }
  }
  return true;
}

