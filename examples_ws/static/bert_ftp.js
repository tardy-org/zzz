
// WS + BERT + FTP Client


// BERT Encoder/Decoder
function tuple(){ return { t: 104, v: Array.apply(null, arguments) }; }
function list(){ return { t: 108, v: Array.apply(null, arguments) }; }
function map(){ return { t: 116, v: Array.apply(null, arguments) }; }
function atom(o){ return { t: 118, v: utf8_enc(o) }; }
function string(o){ return { t: 107, v: utf8_enc(o) }; }
function float(o){ return { t: 70, v: o }; }
function number(o){
  var isInteger = (o % 1 === 0);
  if(isInteger && o >= 0 && o < 256){ return { t: 97, v: o }; }
  if(isInteger && o >= -2147483648 && o <= 2147483647){ return {t: 98, v: o}; }
  return {t: 110, v: o};
}

// BigInt to BERT, with https://github.com/peterolson/BigInteger.js
function bignum(o){
  if(bigInt.isInstance(o) === false){ return {t: 999, v: [97, 0]}; } // o is not bigInt
  if(o.greaterOrEquals(0) && o.lesser(256)){
    // t: 97
    return {t: 999, v: [97, o.toJSNumber() ]};
  }
  if(o.greaterOrEquals(-2147483648) && o.lesserOrEquals(2147483647)){
    // t: 98
    return {t: 999, v: [98, o.shiftRight(24).toJSNumber(), o.shiftRight(16).and(255).toJSNumber(), o.shiftRight(8).and(255).toJSNumber(), o.and(255).toJSNumber() ]};
  }
  // t: 110
  if(o.isNegative()){
    var sign = 1;
    var s = bignum_to_bytes(o.abs());
  }else{
    var sign = 0;
    var s = bignum_to_bytes(o);
  }
  return {t: 999, v: [110, s.length, sign].concat(s) };
}

function bin(o){
  return { t: 109, v: o instanceof ArrayBuffer ? new Uint8Array(o) :
                      o instanceof Uint8Array ? o : utf8_enc(o) };
}


// bert encoder
function enc(o){ return fl([131, ein(o)]); }
function ein(o){
  return Array.isArray(o) ? en_108({ t: 108, v: o }) :
                            (o.t == 999 ? o.v : eval('en_' + o.t)(o) ); // t: 999 = bigInt, already encoded in bignum func
}
function en_undefined(o){ return [106]; }
function unilen(o){
  return (o.v instanceof ArrayBuffer || o.v instanceof Uint8Array) ? o.v.byteLength :
         (new TextEncoder().encode(o.v)).byteLength;
}
function en_70(o){
  var x = Array(8).fill(0).flat();
  write_Float(x, o.v, 0, false, 52, 8);
  return [70].concat(x);
}
function en_97(o){ return [97, o.v]; }
function en_98(o){ return [98, o.v >>> 24, (o.v >>> 16) & 255, (o.v >>> 8) & 255, o.v & 255]; }
function en_99(o){
  var obj = o.v.toExponential(20),
      match = /([^e]+)(e[+-])(\d+)/.exec(obj),
      exponentialPart = match[3].length == 1 ? "0" + match[3] : match[3],
      num = Array.from(bin(match[1] + match[2] + exponentialPart).v);
  return [o.t].concat(num).concat(Array(31 - num.length).fill(0).flat());
}
function en_100(o){ return [100, o.v.length >>> 8, o.v.length & 255, ar(o)]; }
function en_104(o){
  var l = o.v.length,
      r = [];
  for(var i = 0; i < l; i++) r[i] = ein(o.v[i]);
  return [104, l, r];
}
function en_106(o){ return [106]; }
function en_107(o){ return [107, o.v.length >>> 8, o.v.length & 255, ar(o)]; }
function en_108(o){
  var l = o.v.length,
      r = [];
  for(var i = 0; i < l; i++) r.push(ein(o.v[i]));
  return o.v.length == 0 ? [106] :
    [108, l >>> 24, (l >>> 16) & 255, (l >>> 8) & 255, l & 255, r, 106];
}
function en_109(o){
  var l = unilen(o);
  return [109, l >>> 24, (l >>> 16) & 255, (l >>> 8) & 255, l & 255, ar(o)];
}
function en_110(o){
  if(o.v < 0){
    var sign = 1;
    var s = int_to_bytes(-o.v);
  }else{
    var sign = 0;
    var s = int_to_bytes(o.v);
  }
  return [110, s.length, sign].concat(s);
}
function en_115(o){ return [115, o.v.length, ar(o)]; }
function en_116(o){
  var l = o.v.length,
      x = [],
      r = [];
  for(var i = 0; i < l; i++) r.push([ein(o.v[i].k), ein(o.v[i].v)]);
  x = [116, l >>> 24, (l >>> 16) & 255, (l >>> 8) & 255, l & 255];
  return o.v.length == 0 ? x : [x, r];
}
function en_118(o){ return [118, ar(o).length >>> 8, ar(o).length & 255, ar(o)]; }
function en_119(o){ return [119, ar(o).length, ar(o)]; }


// bert decoder
function nop(b){ return []; }
function big(b){
  var sk = b == 1 ? sx.getUint8(ix++) : sx.getInt32((a = ix, ix += 4, a));
  var ret = 0,
      sig = sx.getUint8(ix++),
      count = sk;
  while(count-- > 0){
    ret = 256 * ret + sx.getUint8(ix + count);
  }
  ix += sk;
  return ret * (sig == 0 ? 1 : -1);
}
function int(b){
  return b == 1 ? sx.getUint8(ix++) : sx.getInt32((a = ix, ix += 4, a));
}
function dec(d){
  sx = new DataView(d);
  ix = 0;
  if(sx.getUint8(ix++) !== 131) throw ("BERT?");
  return din();
}
function str(b){
  var dv,
      sz = (b == 2 ? sx.getUint16(ix) : (b == 1 ? sx.getUint8(ix) : sx.getUint32(ix)));
  ix += b;
  var r = sx.buffer.slice(ix, ix += sz);
  return utf8_arr(r);
}
function run(b){
  var sz = (b == 1 ? sx.getUint8(ix) : sx.getUint32(ix)),
      r = [];
      ix += b;
  for(var i = 0; i < sz; i++) r.push(din());
  if(b == 4) ix++;
  return r;
}
function rut(b){
  var sz = (b == 1 ? sx.getUint8(ix) : sx.getUint32(ix)),
      r = [];
      ix += b;
  for(var i = 0; i < sz; i++) r.push(din());
  din();
  return r;
}
function dic(b){
  var sz = sx.getUint32(ix),
      r = [];
      ix += 4;
  for(var i = 0; i < sz; i++) r.push({k: din(), v: din()});
  return r;
}
function iee(x){
  return read_Float(new Uint8Array(sx.buffer.slice(ix, ix += 8)), 0, false, 52, 8);
}

function flo(x){
  return parseFloat(utf8_arr(sx.buffer.slice(ix, ix += 31)));
}

function arr(b){
  var dv,
      sz = sx.getUint16(ix);
  ix += b;
  return new Uint8Array(sx.buffer.slice(ix, ix += sz));
}

function ref(cr){
  var d,
      adj = sx.getUint8(ix++);
  adj += sx.getUint8(ix++);
  d = din();
  ix += cr + adj * 4;
  return d;
}

function din(){
  var x,
      c = sx.getUint8(ix++);
  switch(c){
    case  70: x = [iee, 0]; break;
    case  90: x = [ref, 4]; break;
    case  97: x = [int, 1]; break;
    case  98: x = [int, 4]; break;
    case  99: x = [flo, 0]; break;
    case 100: x = [str, 2]; break;
    case 104: x = [run, 1]; break;
    case 105: x = [run, 4]; break;
    case 107: x = [arr, 2]; break;
    case 108: x = [rut, 4]; break;
    case 109: x = [str, 4]; break;
    case 110: x = [big, 1]; break;
    case 111: x = [big, 4]; break;
    case 114: x = [ref, 1]; break;
    case 115: x = [str, 1]; break;
    case 116: x = [dic, 4]; break;
    case 118: x = [str, 2]; break;
    case 119: x = [str, 1]; break;
    default: x = [nop, 0];
  } return { t: c, v: x[0](x[1]) };
}


// bert helpers
function int_to_bytes(Int){
  if(Int % 1 !== 0) return [0];
  var OriginalInt,
      Rem,
      s = [];
  OriginalInt = Int;
  while(Int !== 0){
    Rem = Int % 256;
    s.push(Rem);
    Int = Math.floor(Int / 256);
  }
  if(Int > 0){ throw ("Argument out of range: " + OriginalInt); }
  return s;
}

function bignum_to_bytes(big_Int){
  var v,
      big_Int,
      s = [];
  big_Int2 = big_Int;
  while(big_Int2.isZero() === false){
    v = big_Int2.divmod(256);
    s.push(v.remainder.toJSNumber());
    big_Int2 = v.quotient;
  }
  if(big_Int2.greater(0)){ throw ("Argument out of range::: " + big_Int.toString() ); }
  return s;
}

function uc(u1, u2){
  if(u1.byteLength == 0) return u2;
  if(u2.byteLength == 0) return u1;
  var a = new Uint8Array(u1.byteLength + u2.byteLength);
  a.set(u1, 0);
  a.set(u2, u1.byteLength);
  return a;
}
function ar(o){
  return o.v instanceof ArrayBuffer ? new Uint8Array(o.v) : o.v instanceof Uint8Array ? o.v :
    Array.isArray(o.v) ? new Uint8Array(o.v) : new Uint8Array(utf8_enc(o.v));
}
function fl(a){
  return a.reduce(function(f, t){
    return uc(f, t instanceof Uint8Array ? t :
      Array.isArray(t) ? fl(t) : new Uint8Array([t]));
  }, new Uint8Array());
}


// save and restore ftp files queue
function saveState(){
  var state = ftp.queue.filter(i => i.status !== 'done').map(i => ({
    id: i.id,
    uid: i.uid,
    name: i.name,
    total: i.total,
    offset: i.offset,
    status: 'paused'
  }));
  localStorage.setItem('ftp_queue', JSON.stringify(state));
}

// todo add cleanState // localStorage.removeItem('ftp_queue');
function restoreState(){
  var stored = localStorage.getItem('ftp_queue');
  if(stored){
    try{
      var items = JSON.parse(stored);
      items.forEach(i => {
        if(ftp.item(i.id)) return; // no dup when too laggy internet
        
        var item = {
          id: i.id,
          uid: i.uid || i.id,
          name: i.name,
          status: 'missing_file', // special
          status_block_id: ftp.status_block_id || 'ftp-status',
          ui_update: (typeof ui_update !== 'undefined') ? ui_update : null,
          autostart: false,
          offset: i.offset,
          block: 32 * 1024,
          total: i.total,
          file: null // no file -- needs to select
        };
        
        ftp.queue.push(item);
        
        if(ui_add){ ui_add(item); }
        if(item.ui_update){ item.ui_update(item, "Please re-select file for resume upload"); }
      });
    
    }catch(e){ console.error("Restore failed: ", e); }
  }
}

// WS FTP Logic
var ftp = {
  queue: [],
  active: false,
  last_save_time: 0, // for save queue - item offset to localStorage
  init: function(file, ui_add = false, ui_update = false){
    var id = Math.floor(Math.random() * 1000000).toString();
    var item = {
      id: id,
      uid: id,
      status: 'init',
      status_block_id: ftp.status_block_id || 'ftp-status',
      ui_update: ui_update,
      autostart: ftp.autostart || false,
      name: ftp.filename || file.name,
      offset: 0,
      block: 32 * 1024, // chunk size 32KB
      total: file.size,
      file: file
    };
    ftp.queue.push(item);
    saveState();
    if(ui_add){ ui_add(item); }
    if(!ftp.active) ftp.start();
    return item.id;
  },
  
  start: function(id){
    if(ftp.active && !id) return;
    var item = id ? ftp.item(id) : ftp.next();
    ftp.active = (item) ? true : false;
    if(item){
      if(item.status === 'init'){
        ftp.send(item, new Uint8Array(0));
      }else{
        ftp.read_slice(item);
      }
    }
  },
  
  stop: function(id){ // pause
    var item = ftp.item(id);
    if(item){
      item.autostart = false;
      if(ftp.active && ftp.current_id === item.id) ftp.active = false;
      if(item.ui_update){ item.ui_update(item, "Paused"); }
      saveState();
    }
  },
  
  resume: function(id){
    var item = ftp.item(id);
    if(item){
      
      if(!item.file || item.status === 'missing_file'){ // after page reload
        console.log("File object lost after reload. Please re-select the file using the input button."); // todo add ui
        return;
      } // otherwise we have files selected already
      
      item.autostart = true;
      item.status = 'init'; // re-init to check offset on server
      if(ftp.current_id === item.id) ftp.active = false;
      if(item.ui_update){ item.ui_update(item, "Resuming..."); }
      if(!ftp.active) ftp.start();
    }
  },
  
  send: function(item, data){
    ftp.current_id = item.id;
    // Tuple: {ftp, Id, Sid, Name, Meta, Other1, Other2, Other3, Total, Offset, Block, Data, Status}
    var msg = tuple(atom('ftp'), bin(item.id), bin(''), bin(item.name), bin(''), bin(''), bin(''), bin(''),
     number(item.total), number(item.offset), number(data.byteLength), bin(data), bin(item.status));
    ws_send(enc(msg)); // ws.send(enc(msg));
  },
  
  read_slice: function(item){
    if(!item.autostart) return;
    var reader = new FileReader();
    reader.onloadend = function(e){
      if(e.target.readyState === FileReader.DONE){
        ftp.send(item, new Uint8Array(e.target.result));
      }
    };
    reader.onerror = function(e){
      console.error("FileReader error:", e.target.error);
      item.autostart = false;
      if(item.ui_update){ item.ui_update(item, "Read error"); }
    };
    var end = item.offset + item.block;
    if(end > item.total) end = item.total;
    reader.readAsArrayBuffer( item.file.slice(item.offset, end) );
  },
  
  item: function(id){ return ftp.queue.find(i => i.id === id || i.uid === id); },
  
  next: function(){ return ftp.queue.find(next => next && next.autostart && (next.status === 'init' || next.offset < next.total) ); }
  //next: function(){ return ftp.queue.find(next => next.offset < next.total); }
};


// main Socket logic
var ws;
var reconnectTimer = null;

function connect(){
  if(ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  
  var proto = window.location.protocol === 'https:' ? 'wss://' : 'ws://';
  ws = new WebSocket(proto + window.location.host + "/ws");
  ws.binaryType = "arraybuffer";
  
  ws.onopen = function(){
    console.log("Connected");
    if(reconnectTimer) { clearInterval(reconnectTimer); reconnectTimer = null; }
    
    var activeItem = ftp.queue.find(i => i.autostart && i.file && i.status !== 'done'); // filter for not complete file uploads for resume
    if(activeItem){
      console.log("Auto-resuming upload:", activeItem.name);
      ftp.active = false;
      activeItem.status = 'init';
      ftp.start(activeItem.id);
    }else{
      if(ftp.active) ftp.start();
    }
  };
  
  ws.onclose = function(){
    console.log("Disconnected. Reconnecting...");
    ws = null;
    if(!reconnectTimer) reconnectTimer = setInterval(connect, 3000);
  };
  
  ws.onerror = function(e){
    console.log("WS Error", e);
    ws.close(); // trigger onclose logic
  };
  
  ws.onmessage = function(evt){
    if(evt.data instanceof ArrayBuffer){
      if(evt.data.byteLength === 0) return; // ignore empty
      try{
        var msg = dec(evt.data);
        //console.log("WS received:", evt.data, msg);
        if(msg.t === 104 && msg.v[0].t === 118 && msg.v[0].v === "ftp"){ // check if tuple {ftp, ...}
          var v = msg.v; // [atom, id, sid, name, meta, o1, o2, o3, total, offset, block, data, status]
          var server_id = utf8_arr(v[1].v); // server returns file_id
          var offset = v[9].v;
          var status = utf8_arr(v[12].v);
          
          //console.log("WS FTP Reply -> ID:", server_id, "Status:", status, "Offset:", offset);
          
          //var item = ftp.item(id);
          var item = ftp.item(server_id); // but if server just changed id (this is answer for init)
          if(!item && ftp.active && ftp.current_id){
            //console.log("Mapping ID, Current: ", ftp.current_id, " Server: ", server_id);
            item = ftp.item(ftp.current_id);
            if(item){
              //console.log("Server assigned ID: ", server_id, " to local: ", item.id);
              item.id = server_id; // but item.uid not changes :)
            }
          }
          
          if(!item){ console.error("Item not found for file_id: ", server_id); return;}
          item.offset = offset;
          
          if(status === "send"){
            item.status = "send";
            item.offset = offset; // 0 for 1st
            
            var now = Date.now();
            if(!ftp.last_save_time || (now - ftp.last_save_time > 2000)){
              saveState();
              ftp.last_save_time = now;
            }
            
            if(item.ui_update){ try{  item.ui_update(item);  }catch(e){ console.error("UI Error ui_update:", e); } }
            
            if(item.offset < item.total){
              try{ ftp.read_slice(item); }catch(e){ console.error("Error in read_slice:", e); }
            }else{
              item.status = 'done';
              saveState();
              
              if(item.ui_update){ item.ui_update(item, "Done!", true); } // console.log("File complete!");
              //ftp.queue = ftp.queue.filter(i => i.id !== item.id);
              item.autostart = true;
              ftp.active = false;
              ftp.start(); // next file
            }
          
          }else if(status === "error"){
            console.error("Server returned ERROR status");
            if(item.ui_update){ item.ui_update(item, "Error: Rejected by server"); }
            item.autostart = false;
          }
        }
      }catch(e){ console.error(e); }
    }
  };
}

function ws_send(data){ // use ws_send(enc(msg)) instead ws.send(enc(msg)) for got status - was send or not
  if(ws && ws.readyState === WebSocket.OPEN){
    ws.send(data);
    return true;
  }else{
    console.warn("WebSocket not open, cannot send"); // todo queue messages or retry later
    return false;
  }
}


// UTF-8 Support
function utf8_dec(ab){ return (new TextDecoder()).decode(ab); }
function utf8_enc(ab){ return (new TextEncoder("utf-8")).encode(ab); }
function utf8_arr(ab){
  if(!(ab instanceof ArrayBuffer)) ab = new Uint8Array(utf8_enc(ab)).buffer;
  return utf8_dec(ab);
}


// IEEE754 (Floats)
function read_Float(buffer, offset, isLE, mLen, nBytes) {
  var e, m
  var eLen = (nBytes * 8) - mLen - 1
  var eMax = (1 << eLen) - 1
  var eBias = eMax >> 1
  var nBits = -7
  var i = isLE ? (nBytes - 1) : 0
  var d = isLE ? -1 : 1
  var s = buffer[offset + i]
  i += d
  e = s & ((1 << (-nBits)) - 1)
  s >>= (-nBits)
  nBits += eLen
  for (; nBits > 0; e = (e * 256) + buffer[offset + i], i += d, nBits -= 8) {}
  m = e & ((1 << (-nBits)) - 1)
  e >>= (-nBits)
  nBits += mLen
  for (; nBits > 0; m = (m * 256) + buffer[offset + i], i += d, nBits -= 8) {}
  if (e === 0) {
    e = 1 - eBias
  } else if (e === eMax) {
    return m ? NaN : ((s ? -1 : 1) * Infinity)
  } else {
    m = m + Math.pow(2, mLen)
    e = e - eBias
  }
  return (s ? -1 : 1) * m * Math.pow(2, e - mLen)
}

function write_Float(buffer, value, offset, isLE, mLen, nBytes) {
  var e, m, c
  var eLen = (nBytes * 8) - mLen - 1
  var eMax = (1 << eLen) - 1
  var eBias = eMax >> 1
  var rt = (mLen === 23 ? Math.pow(2, -24) - Math.pow(2, -77) : 0)
  var i = isLE ? 0 : (nBytes - 1)
  var d = isLE ? 1 : -1
  var s = value < 0 || (value === 0 && 1 / value < 0) ? 1 : 0
  value = Math.abs(value)
  if (isNaN(value) || value === Infinity) {
    m = isNaN(value) ? 1 : 0
    e = eMax
  } else {
    e = Math.floor(Math.log(value) / Math.LN2)
    if (value * (c = Math.pow(2, -e)) < 1) {
      e--
      c *= 2
    }
    if (e + eBias >= 1) {
      value += rt / c
    } else {
      value += rt * Math.pow(2, 1 - eBias)
    }
    if (value * c >= 2) {
      e++
      c /= 2
    }
    if (e + eBias >= eMax) {
      m = 0
      e = eMax
    } else if (e + eBias >= 1) {
      m = ((value * c) - 1) * Math.pow(2, mLen)
      e = e + eBias
    } else {
      m = value * Math.pow(2, eBias - 1) * Math.pow(2, mLen)
      e = 0
    }
  }
  for (; mLen >= 8; buffer[offset + i] = m & 0xff, i += d, m /= 256, mLen -= 8) {}
  e = (e << mLen) | m
  eLen += mLen
  for (; eLen > 0; buffer[offset + i] = e & 0xff, i += d, e /= 256, eLen -= 8) {}
  buffer[offset + i - d] |= s * 128
}

