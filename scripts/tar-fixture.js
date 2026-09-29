// The tar writer the node suites build archive fixtures with,
// scripts/test-convert-v1-themes.js and scripts/test-theme-download.js:
// ustar headers written field by field, so a row can plant a defect no
// archiver writes.
"use strict";
const zlib = require("node:zlib");

// A pax record, `<length> <key>=<value>\n`, its length counting itself.
function paxRecord(key, value) {
    const record = `${key}=${value}\n`;
    let length = Buffer.byteLength(record) + 2;
    for (;;) {
        const next = Buffer.byteLength(String(length)) + 1 + Buffer.byteLength(record);
        if (next === length) return `${length} ${record}`;
        length = next;
    }
}

// The uncompressed tar of ENTRIES, each `{ name, type, data, link, prefix,
// sizeField, badChecksum }`: TYPE the typeflag (default `0`), DATA the
// body, a string or a Buffer, which links, hard links and directories do
// not carry, PREFIX the ustar prefix field, SIZEFIELD the size field's
// twelve bytes in place of DATA's octal length, a string or a Buffer, and
// BADCHECKSUM a header whose checksum no longer matches. Two zero blocks
// end it.
function tarBytes(entries) {
    const blocks = [];
    const checksum = header => {
        for (let i = 148; i < 156; i++) header[i] = 32;
        let sum = 0;
        for (const byte of header) sum += byte;
        header.write(sum.toString(8).padStart(6, "0") + "\0 ", 148, 8, "ascii");
    };
    for (const entry of entries) {
        const data = Buffer.from(entry.data || "");
        const bodiless = entry.type === "1" || entry.type === "2" || entry.type === "5";
        const header = Buffer.alloc(512);
        header.write(entry.name, 0, 100, "utf8");
        header.write("0000644\0", 100, 8, "ascii");
        header.write("0000000\0", 108, 8, "ascii");
        header.write("0000000\0", 116, 8, "ascii");
        const size = entry.sizeField === undefined ? (bodiless ? 0 : data.length).toString(8).padStart(11, "0") + "\0" : entry.sizeField;
        if (Buffer.isBuffer(size)) size.copy(header, 124, 0, 12);
        else header.write(size, 124, 12, "ascii");
        header.write("00000000000\0", 136, 12, "ascii");
        header.write(entry.type || "0", 156, 1, "latin1");
        if (entry.link) header.write(entry.link, 157, 100, "utf8");
        header.write("ustar\0", 257, 6, "ascii");
        header.write("00", 263, 2, "ascii");
        if (entry.prefix) header.write(entry.prefix, 345, 155, "utf8");
        checksum(header);
        if (entry.badChecksum) header[0] = header[0] === 65 ? 66 : 65;
        blocks.push(header);
        if (!bodiless) {
            blocks.push(data);
            const pad = (512 - (data.length % 512)) % 512;
            if (pad > 0) blocks.push(Buffer.alloc(pad));
        }
    }
    blocks.push(Buffer.alloc(1024));
    return Buffer.concat(blocks);
}

// tarBytes gzipped, with no time in the gzip header.
function makeTarGz(entries) {
    return zlib.gzipSync(tarBytes(entries), { mtime: 0 });
}

module.exports = { paxRecord, tarBytes, makeTarGz };
