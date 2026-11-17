// Draws the LFG+ icon, a speech bubble with a plus cut out of it (the same drawing as the
// website's favicon.svg), as the TGA the game loads, with no image library.
//
//   node tools/make-icon.mjs                    writes LFGPlus/Media/Icon.tga
//   node tools/make-icon.mjs --preview out.png  also writes an enlarged PNG preview on the minimap's dark disc
//
// Run it again only when the design changes; the TGA is committed. The game wants a power-of-two size and 32-bit
// colour with straight (not premultiplied) alpha. LibDBIcon shows it at 17-18 px inside the minimap ring; the cut-out
// plus shows the button's dark background through it.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { deflateSync } from 'node:zlib';

const SIZE = 64;
const SUPERSAMPLE = 8;
const ACCENT = [0x4a, 0x8f, 0xe3]; // the website's accent blue
/** The favicon is drawn on a 32 by 32 grid; the texture is twice that. */
const GRID = SIZE / 32;
/**
 * The minimap's frame is round, and the favicon's drawing fills its square: drawn as it is, the frame clips the
 * bubble's corners and, since the tail hangs below, the bubble's body sits high. So the texture draws it a little
 * smaller, with the body's centre (16, 13.5 on the grid) at the middle of the circle.
 */
const SCALE = 0.85;
const BODY_CENTRE_Y = 13.5;

/** Distance from (x, y) to the segment from (ax, ay) to (bx, by). */
function segmentDistance(x, y, ax, ay, bx, by) {
    const dx = bx - ax, dy = by - ay;
    const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
    return Math.hypot(x - (ax + t * dx), y - (ay + t * dy));
}

/** Whether (x, y) is inside the rounded rectangle from (2, 3) to (30, 24), corner radius 6: the bubble's body. */
function inBody(x, y) {
    const qx = Math.abs(x - 16) - (14 - 6), qy = Math.abs(y - 13.5) - (10.5 - 6);
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) <= 6;
}

/** Whether (x, y) is inside the tail, a polygon from the body's bottom edge down to its tip at the bottom left. */
const TAIL = [[6.5, 20], [14.2, 24], [7.6, 29.3], [6.5, 28.6]];
function inTail(x, y) {
    let inside = false;
    for (let i = 0, j = TAIL.length - 1; i < TAIL.length; j = i++) {
        const [xi, yi] = TAIL[i], [xj, yj] = TAIL[j];
        if ((yi > y) !== (yj > y) && x < ((xj - xi) * (y - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
}

/** Whether (x, y) is inside the plus cut out of the middle: two round-ended strokes 4.2 wide. */
function inPlus(x, y) {
    return Math.min(segmentDistance(x, y, 16, 8.6, 16, 18.4), segmentDistance(x, y, 11.1, 13.5, 20.9, 13.5)) <= 2.1;
}

/** Coverage of the icon over one pixel, from 0 to 1. */
function coverage(px, py) {
    let inside = 0;
    for (let sy = 0; sy < SUPERSAMPLE; sy++) {
        for (let sx = 0; sx < SUPERSAMPLE; sx++) {
            // From the texture's pixel back to the favicon's grid.
            const x = 16 + ((px + (sx + 0.5) / SUPERSAMPLE) / GRID - 16) / SCALE;
            const y = BODY_CENTRE_Y + ((py + (sy + 0.5) / SUPERSAMPLE) / GRID - 16) / SCALE;
            if ((inBody(x, y) || inTail(x, y)) && !inPlus(x, y)) inside++;
        }
    }
    return inside / (SUPERSAMPLE * SUPERSAMPLE);
}

// RGBA, top row first.
const rgba = new Uint8Array(SIZE * SIZE * 4);
for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
        const i = (y * SIZE + x) * 4;
        rgba.set(ACCENT, i);
        rgba[i + 3] = Math.round(coverage(x, y) * 255);
    }
}

/** An uncompressed 32-bit TGA, top-left origin. */
function tga(pixels, size) {
    const header = new Uint8Array(18);
    header[2] = 2;                       // uncompressed true colour
    header[12] = size & 0xff; header[13] = size >> 8;
    header[14] = size & 0xff; header[15] = size >> 8;
    header[16] = 32;                     // bits per pixel
    header[17] = 0x28;                   // 8 alpha bits, top-left origin
    const body = new Uint8Array(size * size * 4);
    for (let i = 0; i < size * size; i++) {
        body[i * 4] = pixels[i * 4 + 2];     // B
        body[i * 4 + 1] = pixels[i * 4 + 1]; // G
        body[i * 4 + 2] = pixels[i * 4];     // R
        body[i * 4 + 3] = pixels[i * 4 + 3]; // A
    }
    return Buffer.concat([header, body]);
}

const CRC_TABLE = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
});
function crc32(bytes) {
    let c = 0xffffffff;
    for (const b of bytes) c = CRC_TABLE[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
}
function pngChunk(type, data) {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0);
    out.write(type, 4, 'latin1');
    data.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
    return out;
}
/** An RGBA PNG. */
function png(pixels, width, height) {
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0); ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8; ihdr[9] = 6;
    const raw = Buffer.alloc(height * (width * 4 + 1));
    for (let y = 0; y < height; y++) Buffer.from(pixels.subarray(y * width * 4, (y + 1) * width * 4)).copy(raw, y * (width * 4 + 1) + 1);
    return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        pngChunk('IHDR', ihdr), pngChunk('IDAT', deflateSync(raw)), pngChunk('IEND', Buffer.alloc(0))]);
}

/** The icon on a dark disc, like the minimap button's background, at `scale` times, with nearest-neighbour pixels. */
function preview(scale) {
    const size = SIZE * scale;
    const out = new Uint8Array(size * size * 4);
    const bg = [0x0f, 0x11, 0x15];
    for (let y = 0; y < size; y++) {
        for (let x = 0; x < size; x++) {
            const s = ((Math.floor(y / scale) * SIZE) + Math.floor(x / scale)) * 4;
            const a = rgba[s + 3] / 255;
            const inDisc = Math.hypot(x + 0.5 - size / 2, y + 0.5 - size / 2) <= size / 2;
            const o = (y * size + x) * 4;
            for (let c = 0; c < 3; c++) out[o + c] = Math.round(rgba[s + c] * a + bg[c] * (1 - a));
            out[o + 3] = inDisc ? 255 : 0;
        }
    }
    return png(out, size, size);
}

const target = fileURLToPath(new URL('../LFGPlus/Media/Icon.tga', import.meta.url));
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, tga(rgba, SIZE));
console.log(`Wrote ${target}`);

const previewAt = process.argv.indexOf('--preview');
if (previewAt !== -1 && process.argv[previewAt + 1]) {
    writeFileSync(process.argv[previewAt + 1], preview(4));
    console.log(`Wrote ${process.argv[previewAt + 1]}`);
}
