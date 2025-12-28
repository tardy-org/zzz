# zzz webserver ws examples

```
zig 0.14.1

zig build
zig build ex_ws_1
zig build ex_ws_2
zig build ex_ws_3
zig build ex_ws_4

# ws example
./ex_ws_1
// goto http://localhost:3010/ , open browser webmaster console
ws.send(42);
ws.send("hello world");
// in debug build you can see log of received messages


# wss example (with cert) // you need sudo because port 443 used
sudo ./ex_ws_2
// goto https://test1.ls/ , open browser webmaster console
ws.send(42);
ws.send("hello world");


# ws PubSub example
sudo ./ex_ws_3
// goto http://localhost:3010/ in one browser(or common window - non-private), open browser webmaster console

// also open the same http://localhost:3010/ in second browser(or private window), open browser webmaster console
ws.send("general:hello");
ws.send("general:42");
ws.send("gen:777");

// check received messages in second window, also send there
ws.send("general:hello 2");
ws.send("general:43");
ws.send("gen:hello");
// and check received messages in first window


# ws file upload example, with queue and pause-resume feature
./ex_ws_4
// goto http://localhost:3010/ , select files for upload
```

