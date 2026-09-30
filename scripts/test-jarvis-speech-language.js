#!/usr/bin/env node
// Synthetic language fixtures for desktop/system answer text, 2026-09-30.
"use strict";
const { assert, path, backend, world, control } = require("./fixtures/jarvis-voice/assertions.js");
const Language = require(path.join(backend, "SpeechLanguage.js"));
const cases = [
    ["en", "0 21 100 101 999 1000", "zero twenty one one hundred one hundred one nine hundred ninety nine one thousand"],
    ["es", "0 21 100 101 999 1000", "cero veintiuno cien ciento uno novecientos noventa y nueve mil"],
    ["en", "1,000,000 1,000,000,000", "one million one billion"],
    ["es", "1.000.000 2.000.000 1.000.000.000", "un millón dos millones mil millones"],
    ["en", "0007 1234567890123", "zero zero zero seven one two three four five six seven eight nine zero one two three"],
    ["es", "0007 -0,05", "cero cero cero siete menos cero coma cero cinco"],
    ["en", "1 ms 2 GiB 3 km", "one millisecond two gibibytes three kilometres"],
    ["es", "1 h 1% 1 kg", "una hora uno por ciento un kilogramo"],
    ["en", "2024-02-29 00:00", "February twenty ninth two thousand twenty four midnight"],
    ["es", "2024-02-29 23:59", "veintinueve de febrero de dos mil veinticuatro veintitrés y cincuenta y nueve"],
    ["en", "$ 2 00:05", "two dollars twelve oh five"],
    ["es", "21 kg 31 h", "veintiún kilogramos treinta y una horas"],
    ["es", "21.000 21.000.000 31.000 31.000.000", "veintiún mil veintiún millones treinta y un mil treinta y un millones"],
    ["en", "3rd 21st 11th 12th 13th 22nd 100th 101st 1000th", "third twenty first eleventh twelfth thirteenth twenty second one hundredth one hundred first one thousandth"],
    ["es", "1º 2ª 21º 31ª 100º 1001º", "primero segunda vigésimo primero trigésima primera centésimo milésimo primero"],
    ["en", "v128 IPv6 MP3 4K v1.2", "v one two eight IPv six MP three four K v one . two"],
    ["es", "v128 IPv6 MP3 4K", "v uno dos ocho IPv seis MP tres cuatro K"],
    ["en", "20 MB/s 50 km/h", "twenty megabytes per second fifty kilometres per hour"],
    ["es", "20 MB/s 50 km/h", "veinte megabytes por segundo cincuenta kilómetros por hora"]
];
function expanded(logic, row) { assert.equal(logic.expand(row[1], row[0], () => {}), row[2]); }
for (const row of cases) expanded(Language, row);
assert.equal(Language.languageCode(""), "en");
for (const choice of ["de", "en-US", undefined, null, "../es"])
    assert.throws(() => Language.languageCode(choice), { message: "jarvis: speech=language" });
const seen = [];
Language.expand("2026-02-31 24:99", "en", kind => seen.push(kind));
assert.equal(seen.includes("date"), false, "invalid ISO date is not guessed");
assert.equal(seen.includes("time"), false, "invalid clock time is not guessed");
let controls = 0;
world("jl", root => {
    for (const [name, needle, replacement, check] of [
        ["language", 'throw new Error("jarvis: speech=language");', 'return "en";',
            logic => assert.throws(() => logic.languageCode("de"), { message: "jarvis: speech=language" })],
        ["number", 'integer(Number(whole), code);', '"number";', logic => expanded(logic, cases[0])],
        ["unit", 'UNITS[chosen][code === "en" ? 0 : 1][singular ? 0 : 1]',
            'chosen', logic => expanded(logic, cases[6])],
        ["date", 'note("date");', 'note("date"); return raw;', logic => expanded(logic, cases[8])],
        ["time", 'note("time");', 'note("time"); return raw;', logic => expanded(logic, cases[9])]
    ]) {
        control(root, name, "SpeechLanguage.js", needle, replacement, check); controls++;
    }
    for (const [name, needle, replacement, example] of [
        ["scale-agreement", 'spanishAgreement(integer(count, code)) + " "', 'integer(count, code) + " "', 12],
        ["accent-agreement", '.replace(/veintiuno$/, "veintiún")', '.replace(/veintiuno$/, "veintiun")', 12],
        ["ordinal", 'const spoken = ordinal(n, code);', 'const spoken = digits;', 13],
        ["ordinal-gender", 'suffix === "ª" ? spoken.replace(/o\\b/gu, "a") : spoken',
            'false ? spoken.replace(/o\\b/gu, "a") : spoken', 14],
        ["identifier-digits", 'return " " + [...digits].map(digit => SMALL[code][Number(digit)]).join(" ") + " ";',
            'return digits;', 15],
        ["unit-rate", 'spoken += (code === "en" ? " per " : " por ") + UNITS[rate][code === "en" ? 0 : 1][0];',
            'spoken += "";', 17]
    ]) {
        control(root, name, "SpeechLanguage.js", needle, replacement, logic => expanded(logic, cases[example])); controls++;
    }
    for (const [name, needle, replacement, input, kind] of [
        ["invalid-date", 'year < 100 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day',
            'false', "2026-02-31", "date"],
        ["invalid-time", 'hour > 23 || minute > 59', 'false', "24:59", "time"]
    ]) {
        control(root, name, "SpeechLanguage.js", needle, replacement, logic => {
            const seen = [];
            logic.expand(input, "en", kind => seen.push(kind));
            assert.equal(seen.includes(kind), false);
        }); controls++;
    }
});
console.log("test-jarvis-speech-language: ok cases=" + cases.length + " controls=" + controls);
