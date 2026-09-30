// TTS input boundary for chained consumers. create(language) owns a text
// stream: push(chunk) and finish() return sentence arrays; counts() returns
// detected violations without retaining a transcript. violations(text,
// language) measures a final duplex transcript. It never receives audio.
// Limits are allocation bounds in UTF-16 code units, not latency budgets.
// Any overflow throws, clears retained text and makes the stream unusable.
"use strict";
const { languageCode, expand } = require("./SpeechLanguage.js");
const LIMITS = Object.freeze({ chunk: 16384, token: 4096, sentence: 4096, output: 65536 });
const KINDS = ["markdown", "code", "url", "path", "symbol", "number", "unit", "date", "time"];
const URL_START = /^(?:[A-Za-z][A-Za-z0-9+.-]*:\/\/|www\.|mailto:)/u;
// A brain can split any URI scheme across tokens. Hold one possible scheme
// until punctuation/whitespace disproves it, rather than maintain a scheme list.
const SCHEME_PART = /^[A-Za-z][A-Za-z0-9+.-]*(?::\/{0,2})?$/u;
const ABBREVIATIONS = /(?:\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Sra|Srta|Ud|Uds)|\b[A-Z])\.$/u;
const HTML_TAG = /^<\/?[A-Za-z][A-Za-z0-9:-]*(?:\s+[A-Za-z_:][A-Za-z0-9_:.-]*(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?)*\s*\/?>/u;
const HTML_OTHER = /^(?:<!--[\s\S]*?-->|<!DOCTYPE\s+[^<>]+>|<\?[A-Za-z][\s\S]*?\?>)/iu;

function siteName(raw) {
    try {
        const parsed = new URL(raw.startsWith("www.") ? "https://" + raw : raw);
        const host = parsed.protocol === "mailto:" ? parsed.pathname.split("@").at(-1) : parsed.hostname;
        // A spoken site label, not an authority or a public-suffix judge.
        const parts = host.replace(/^www\./, "").split(".");
        return parts.length > 1 ? parts.slice(0, -1).join(" ") : host;
    } catch {
        // A model can emit a malformed URL. Never send its address to TTS.
        return "";
    }
}

/** Own one brain-text stream. The engine sends only returned strings to TTS. */
function create(language) {
    const code = languageCode(language);
    let pending = "";
    let sentence = "";
    let mode = "prose";
    let fence = "";
    let lifecycle = "open";
    const counts = Object.fromEntries(KINDS.map(kind => [kind, 0]));

    function note(kind) {
        if (!Object.hasOwn(counts, kind)) throw new Error("jarvis: speakable=violation-kind");
        if (counts[kind] === Number.MAX_SAFE_INTEGER) throw new Error("jarvis: speakable=count-overflow");
        counts[kind]++;
    }
    function bound(text, size, name) {
        if (text.length > size) throw new Error("jarvis: speakable=" + name + "-overflow");
    }
    function emit(raw, output) {
        let text = expand(raw, code, note);
        text = text.replace(/[^\p{L}\p{M}\p{N}\s.,!?¿¡;:'’"()-]/gu, () => { note("symbol"); return " "; })
            .replace(/\s+/gu, " ").replace(/\s+([.,!?;:])/gu, "$1").trim();
        // Do not offer a punctuation-only "sentence" to the speech adapter.
        if (!/[\p{L}\p{N}]/u.test(text)) return;
        output.push(text);
        if (output.reduce((size, item) => size + item.length, 0) > LIMITS.output)
            throw new Error("jarvis: speakable=output-overflow");
    }
    function plain(text, output) {
        sentence += text;
        bound(sentence, LIMITS.sentence, "sentence");
        // Lookahead keeps a fragmented decimal point or final punctuation
        // pending until whitespace arrives. Code and URLs never enter here.
        let from = 0;
        for (;;) {
            const cut = /[.!?]+(?=\s)/u.exec(sentence.slice(from));
            if (cut === null) break;
            const end = from + cut.index + cut[0].length;
            if (cut[0] === "." && ABBREVIATIONS.test(sentence.slice(0, end))) { from = end; continue; }
            emit(sentence.slice(0, end), output);
            sentence = sentence.slice(end).trimStart();
            from = 0;
        }
    }
    function drain(final, output) {
        while (pending !== "") {
            if (mode !== "prose") {
                switch (mode) {
                case "code":
                    if (pending.startsWith(fence)) { pending = pending.slice(fence.length); mode = "prose"; plain(" ", output); }
                    else if (!final && fence.startsWith(pending)) return;
                    else pending = pending.slice(1);
                    continue;
                default: throw new Error("jarvis: speakable=mode");
                }
            }
            const first = pending[0];
            // A chunk may end inside a UTF-16 pair. Preserve it for the next.
            if (!final && pending.length === 1 && /[\uD800-\uDBFF]/u.test(first)) return;
            const ticks = /^(`+|~{3,})/.exec(pending);
            if (ticks) {
                if (!final && ticks[0].length === pending.length) return;
                fence = ticks[0];
                pending = pending.slice(ticks[0].length);
                mode = "code";
                note("code");
                continue;
            }
            if (!final && /^~{1,2}$/.test(pending)) return;
            if (first === "<") {
                // Angle-wrapped URLs are still URLs, not HTML.
                if (!final && pending === "<") return;
                if (URL_START.test(pending.slice(1))) { pending = pending.slice(1); continue; }
                if (!final && SCHEME_PART.test(pending.slice(1))) return;
                const tag = HTML_TAG.exec(pending) || HTML_OTHER.exec(pending);
                if (tag !== null) {
                    note("markdown"); pending = pending.slice(tag[0].length); continue;
                }
                // A possible tag stays bounded and pending until it closes.
                // At EOF it is prose, not permission to discard the turn.
                if (!final && /^<[A-Za-z/!?]/u.test(pending)) return;
                plain("<", output); pending = pending.slice(1); continue;
            }
            const url = URL_START.test(pending);
            if (url) {
                const end = pending.search(/[\s<>()\[\]]/u);
                if (end === -1 && !final) return;
                const length = end === -1 ? pending.length : end;
                const token = pending.slice(0, length);
                const trailing = /[.,!?;:]+$/.exec(token)?.[0] || "";
                const address = trailing ? token.slice(0, -trailing.length) : token;
                note("url");
                plain(siteName(address) + trailing, output);
                pending = pending.slice(length);
                continue;
            }
            if (!final && SCHEME_PART.test(pending)) return;
            const image = pending.startsWith("![");
            if (first === "[" || image) {
                const start = image ? 2 : 1;
                const close = pending.indexOf("]", start);
                if (!final && (close === -1 || close === pending.length - 1)) return;
                if (close !== -1 && pending[close + 1] === "(") {
                    const end = pending.indexOf(")", close + 2);
                    if (!final && end === -1) return;
                    // Unfinished link targets are discarded on finish.
                    const label = image ? "" : pending.slice(start, close);
                    note("markdown");
                    pending = label + " " + (end === -1 ? "" : pending.slice(end + 1));
                    continue;
                }
                note("markdown"); pending = pending.slice(start); continue;
            }
            if (!final && pending === "!") return;
            const pathBoundary = sentence === "" || /[\s([{'"]$/u.test(sentence);
            const path = pathBoundary && /^(?:\/[\p{L}\p{N}_.]|~\/|[A-Za-z]:\\)/u.test(pending);
            if (path) {
                const end = pending.search(/\s/u);
                if (end === -1 && !final) return;
                const length = end === -1 ? pending.length : end;
                const trailing = /[.,!?;:]+$/.exec(pending.slice(0, length))?.[0] || "";
                note("path"); plain(" " + trailing, output); pending = pending.slice(length); continue;
            }
            if (!final && (pending === "/" || pending === "~" || /^[A-Za-z]:?\\?$/.test(pending))) return;
            if (/^[*_~#>|\\\[\]]/u.test(first)) {
                note("markdown"); pending = pending.slice(1); plain(" ", output); continue;
            }
            // Markdown list bullets and ordered markers are layout, not speech.
            if ((sentence === "" || sentence.endsWith("\n")) && /^[-+]\s/u.test(pending)) {
                note("markdown"); pending = pending.slice(1); continue;
            }
            if (!final && (first === "-" || first === "+") && pending.length === 1) return;
            const ordered = /^\d+[.)]\s/u.exec(pending);
            if ((sentence === "" || sentence.endsWith("\n")) && ordered) {
                if (!final && ordered[0].length === pending.length) return;
                if (/^\p{L}/u.test(pending.slice(ordered[0].length))) {
                    note("markdown"); pending = pending.slice(ordered[0].length); continue;
                }
            }
            if (!final && (sentence === "" || sentence.endsWith("\n")) && /^\d+[.)]?\s*$/u.test(pending)) return;
            const char = pending.codePointAt(0);
            const width = char > 0xffff ? 2 : 1;
            plain(pending.slice(0, width), output);
            pending = pending.slice(width);
        }
    }
    function run(chunk, final) {
        if (lifecycle !== "open") throw new Error("jarvis: speakable=stream-" + lifecycle);
        try {
            if (typeof chunk !== "string") throw new Error("jarvis: speakable=chunk-type");
            bound(chunk, LIMITS.chunk, "chunk");
            const output = [];
            // Feed bounded pieces before retaining them. No combined chunk
            // allocation grows beyond the pending token ceiling.
            for (const char of chunk) {
                pending += char;
                bound(pending, LIMITS.token, "token");
                drain(false, output);
            }
            if (final) {
                drain(true, output);
                emit(sentence, output);
                sentence = ""; fence = ""; mode = "prose";
                lifecycle = "closed";
            }
            return output;
        } catch (error) {
            pending = ""; sentence = ""; fence = ""; mode = "prose"; lifecycle = "failed";
            throw error;
        }
    }
    return Object.freeze({
        /** Consume an arbitrary text chunk; return completed spoken sentences. */
        push(chunk) { return run(chunk, false); },
        /** Close the text stream and return its final fragment, if any. */
        finish() { return run("", true); },
        /** Snapshot machine-detectable violations, with no transcript or audio. */
        counts() { return Object.freeze({ ...counts }); }
    });
}

/** Count final transcript violations. Call once per non-overlapping text window. */
function violations(text, language) {
    const stream = create(language);
    stream.push(text);
    stream.finish();
    return stream.counts();
}

module.exports = { create, violations, limits: LIMITS };
