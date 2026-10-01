// Loopback WebSocket server side for Jarvis suites: RFC 6455 § 4.2.2 opening
// handshake and § 5.2 base framing with 7, 16 and 64-bit payload lengths.
// Synthetic, 2026-10-01. Client frames must be masked and final; this side
// sends unmasked frames. No extension, subprotocol or fragmentation.
"use strict";
const assert = require("node:assert/strict");
const { createHash } = require("node:crypto");

const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** Answer an upgrade request on its raw socket. */
function accept(request, socket) {
    const key = createHash("sha1").update(request.headers["sec-websocket-key"] + GUID).digest("base64");
    socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: " + key + "\r\n\r\n");
}

/** One unmasked, final server frame. */
function frame(opcode, payload) {
    const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
    let header;
    if (body.length < 126) header = Buffer.from([0x80 | opcode, body.length]);
    else if (body.length < 65536) {
        header = Buffer.alloc(4);
        header[0] = 0x80 | opcode;
        header[1] = 126;
        header.writeUInt16BE(body.length, 2);
    } else {
        header = Buffer.alloc(10);
        header[0] = 0x80 | opcode;
        header[1] = 127;
        header.writeBigUInt64BE(BigInt(body.length), 2);
    }
    return Buffer.concat([header, body]);
}

/** Feed socket chunks; onFrame receives each unmasked {opcode, payload}. */
function decoder(onFrame) {
    let pending = Buffer.alloc(0);
    return chunk => {
        pending = Buffer.concat([pending, chunk]);
        for (;;) {
            if (pending.length < 2) return;
            assert.equal(pending[0] & 0x80, 0x80, "fixture expects final client frames");
            assert.equal(pending[1] & 0x80, 0x80, "client frames are masked");
            let length = pending[1] & 127;
            let offset = 2;
            if (length === 126) {
                if (pending.length < 4) return;
                length = pending.readUInt16BE(2);
                offset = 4;
            } else if (length === 127) {
                if (pending.length < 10) return;
                length = Number(pending.readBigUInt64BE(2));
                offset = 10;
            }
            if (pending.length < offset + 4 + length) return;
            const mask = pending.subarray(offset, offset + 4);
            const payload = Buffer.from(pending.subarray(offset + 4, offset + 4 + length));
            payload.forEach((byte, index) => { payload[index] = byte ^ mask[index % 4]; });
            const opcode = pending[0] & 15;
            pending = pending.subarray(offset + 4 + length);
            onFrame({ opcode, payload });
        }
    };
}

module.exports = { accept, frame, decoder };
