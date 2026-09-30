// The one language judge used by guidance and TTS sanitation.
// languageCode("") selects English; only explicit "en" and "es" are offered.
// expand(text, language, note) expands numeric speech. note(kind) records
// number/unit/date/time replacements for the duplex transcript instrument.
// Input is one bounded Speakable sentence. This module keeps no store.
"use strict";
const SMALL = {
    en: ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen"],
    es: ["cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
        "diez", "once", "doce", "trece", "catorce", "quince", "dieciséis", "diecisiete",
        "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidós", "veintitrés",
        "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve"]
};
const TENS = {
    en: ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"],
    es: ["", "", "", "treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa"]
};
const HUNDREDS = ["", "ciento", "doscientos", "trescientos", "cuatrocientos", "quinientos",
    "seiscientos", "setecientos", "ochocientos", "novecientos"];
const MONTHS = {
    en: ["January", "February", "March", "April", "May", "June", "July", "August",
        "September", "October", "November", "December"],
    es: ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio", "agosto",
        "septiembre", "octubre", "noviembre", "diciembre"]
};
const DAYS_EN = ["", "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
    "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
    "eighteenth", "nineteenth", "twentieth", "twenty first", "twenty second", "twenty third",
    "twenty fourth", "twenty fifth", "twenty sixth", "twenty seventh", "twenty eighth",
    "twenty ninth", "thirtieth", "thirty first"];
const ORDINALS_ES = [
    ["", "primero", "segundo", "tercero", "cuarto", "quinto", "sexto", "séptimo", "octavo", "noveno"],
    ["", "décimo", "vigésimo", "trigésimo", "cuadragésimo", "quincuagésimo", "sexagésimo", "septuagésimo", "octogésimo", "nonagésimo"],
    ["", "centésimo", "ducentésimo", "tricentésimo", "cuadringentésimo", "quingentésimo", "sexcentésimo", "septingentésimo", "octingentésimo", "noningentésimo"]
];
// Singular, plural, for the units a brain's desktop/system answer can emit.
const UNITS = {
    "%": [["percent", "percent"], ["por ciento", "por ciento"]],
    kg: [["kilogram", "kilograms"], ["kilogramo", "kilogramos"]],
    g: [["gram", "grams"], ["gramo", "gramos"]],
    km: [["kilometre", "kilometres"], ["kilómetro", "kilómetros"]],
    m: [["metre", "metres"], ["metro", "metros"]],
    cm: [["centimetre", "centimetres"], ["centímetro", "centímetros"]],
    mm: [["millimetre", "millimetres"], ["milímetro", "milímetros"]],
    s: [["second", "seconds"], ["segundo", "segundos"]],
    ms: [["millisecond", "milliseconds"], ["milisegundo", "milisegundos"]],
    min: [["minute", "minutes"], ["minuto", "minutos"]],
    h: [["hour", "hours"], ["hora", "horas"]],
    Hz: [["hertz", "hertz"], ["hercio", "hercios"]],
    W: [["watt", "watts"], ["vatio", "vatios"]],
    B: [["byte", "bytes"], ["byte", "bytes"]],
    KB: [["kilobyte", "kilobytes"], ["kilobyte", "kilobytes"]],
    MB: [["megabyte", "megabytes"], ["megabyte", "megabytes"]],
    GB: [["gigabyte", "gigabytes"], ["gigabyte", "gigabytes"]],
    TB: [["terabyte", "terabytes"], ["terabyte", "terabytes"]],
    KiB: [["kibibyte", "kibibytes"], ["kibibyte", "kibibytes"]],
    MiB: [["mebibyte", "mebibytes"], ["mebibyte", "mebibytes"]],
    GiB: [["gibibyte", "gibibytes"], ["gibibyte", "gibibytes"]],
    "°C": [["degree Celsius", "degrees Celsius"], ["grado Celsius", "grados Celsius"]],
    "°F": [["degree Fahrenheit", "degrees Fahrenheit"], ["grado Fahrenheit", "grados Fahrenheit"]],
    "$": [["dollar", "dollars"], ["dólar", "dólares"]],
    "€": [["euro", "euros"], ["euro", "euros"]]
};

/** Resolve a session's offered language. Unsupported choices fail explicitly. */
function languageCode(language) {
    if (language === "") return "en";
    if (language === "en" || language === "es") return language;
    throw new Error("jarvis: speech=language");
}

function spanishAgreement(text, feminine = false) {
    return feminine ? text.replace(/uno$/, "una") : text.replace(/veintiuno$/, "veintiún").replace(/uno$/, "un");
}

function integer(n, code) {
    if (n < SMALL[code].length) return SMALL[code][n];
    if (n < 100) {
        const rest = n % 10;
        return TENS[code][Math.floor(n / 10)] + (rest ? (code === "en" ? " " : " y ") + integer(rest, code) : "");
    }
    if (n < 1000) {
        if (code === "es" && n === 100) return "cien";
        return (code === "en" ? integer(Math.floor(n / 100), code) + " hundred" : HUNDREDS[Math.floor(n / 100)])
            + (n % 100 ? " " + integer(n % 100, code) : "");
    }
    const scales = code === "en"
        ? [[1000000000, "billion"], [1000000, "million"], [1000, "thousand"]]
        : [[1000000, "millón"], [1000, "mil"]];
    for (const [size, word] of scales) {
        if (n < size) continue;
        const count = Math.floor(n / size);
        let prefix = integer(count, code) + " " + word;
        if (code === "es") {
            if (size === 1000 && count === 1) prefix = "mil";
            else prefix = spanishAgreement(integer(count, code)) + " " + (size === 1000000 && count !== 1 ? "millones" : word);
        }
        return prefix + (n % size ? " " + integer(n % size, code) : "");
    }
    throw new Error("jarvis: speech=integer");
}

function ordinal(n, code) {
    if (code === "en") {
        if (n === 0) return "zeroth";
        if (n < DAYS_EN.length) return DAYS_EN[n];
        const words = integer(n, code).split(" ");
        const last = words.pop();
        const small = SMALL.en.indexOf(last);
        words.push(small > 0 ? DAYS_EN[small] : last.endsWith("y") ? last.slice(0, -1) + "ieth" : last + "th");
        return words.join(" ");
    }
    if (n === 0) return "cero";
    if (n < 1000) {
        return [2, 1, 0].map(power => ORDINALS_ES[power][Math.floor(n / (10 ** power)) % 10])
            .filter(word => word !== "").join(" ");
    }
    const size = n >= 1000000 ? 1000000 : 1000;
    const count = Math.floor(n / size);
    const prefix = count === 1 ? "" : spanishAgreement(integer(count, code))
        .normalize("NFD").replace(/\p{M}|\s/gu, "");
    return prefix + (size === 1000 ? "milésimo" : "millonésimo")
        + (n % size ? " " + ordinal(n % size, code) : "");
}

function number(raw, code) {
    const negative = raw.startsWith("-");
    raw = raw.replace(/^[-+]/, "");
    const group = code === "en" ? "," : ".";
    const decimal = code === "en" ? "." : ",";
    const parts = raw.split(decimal);
    const whole = parts[0].split(group).join("");
    // Large identifiers and leading-zero values use digits, not rounded doubles.
    const words = whole.length > 12 || (whole.length > 1 && whole[0] === "0")
        ? [...whole].map(digit => SMALL[code][Number(digit)]).join(" ")
        : integer(Number(whole), code);
    return (negative ? (code === "en" ? "minus " : "menos ") : "") + words
        + (parts.length > 1 ? (code === "en" ? " point " : " coma ")
            + [...parts[1]].map(digit => SMALL[code][Number(digit)]).join(" ") : "");
}

/** Expand numbers, ordinals, identifier digits, units, rates, dates and times. */
function expand(text, language, note) {
    const code = languageCode(language);
    text = text.replace(/\b(\d{4})-(\d{2})-(\d{2})\b/g, (raw, y, m, d) => {
        const year = Number(y), month = Number(m), day = Number(d);
        const date = new Date(Date.UTC(year, month - 1, day));
        if (year < 100 || date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return raw;
        note("date");
        return code === "en" ? MONTHS.en[month - 1] + " " + DAYS_EN[day] + " " + integer(year, code)
            : integer(day, code) + " de " + MONTHS.es[month - 1] + " de " + integer(year, code);
    });
    text = text.replace(/\b(\d{1,2}):(\d{2})\b/g, (raw, h, m) => {
        const hour = Number(h), minute = Number(m);
        if (hour > 23 || minute > 59) return raw;
        note("time");
        if (hour === 0 && minute === 0) return code === "en" ? "midnight" : "medianoche";
        return integer(code === "en" && hour === 0 ? 12 : hour, code) + (minute === 0 ? (code === "en" ? " o'clock" : " en punto")
            : (code === "en" ? (minute < 10 ? " oh " : " ") : " y ") + integer(minute, code));
    });
    const group = code === "en" ? "," : ".";
    const groupedInteger = code === "en" ? "(?:\\d{1,3}(?:,\\d{3})+|\\d+)" : "(?:\\d{1,3}(?:\\.\\d{3})+|\\d+)";
    const numeric = groupedInteger + (code === "en" ? "(?:\\.\\d+)?" : "(?:,\\d+)?");
    const ordinalPattern = new RegExp("(?<![\\p{L}\\p{N}.,])(" + groupedInteger + ")"
        + (code === "en" ? "(st|nd|rd|th)" : "\\.?(º|ª)") + "(?![\\p{L}\\p{N}])", "gu");
    text = text.replace(ordinalPattern, (raw, digits, suffix) => {
        const whole = digits.split(group).join("");
        if (whole.length > 12) return raw;
        const n = Number(whole);
        if (code === "en") {
            const ending = n % 100 >= 11 && n % 100 <= 13 ? "th" : ({ 1: "st", 2: "nd", 3: "rd" }[n % 10] || "th");
            if (suffix !== ending) return raw;
        }
        note("number");
        const spoken = ordinal(n, code);
        return suffix === "ª" ? spoken.replace(/o\b/gu, "a") : spoken;
    });
    const units = Object.keys(UNITS).sort((a, b) => b.length - a.length)
        .map(unit => unit.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
    const pattern = new RegExp("(?<![\\p{L}\\p{N}])(?:([$€])\\s*)?([-+]?" + numeric + ")(?:\\s*(" + units
        + ")(?![\\p{L}\\p{N}])(?:\\s*/\\s*(" + units + ")(?![\\p{L}\\p{N}]))?)?(?![\\p{L}\\p{N}]|[.,]\\d)"
        + "|([-+]?[\\p{L}\\p{N}]+(?:[.,-][\\p{L}\\p{N}]+)*)", "gu");
    return text.replace(pattern, (raw, currency, amount, unit, rate, identifier) => {
        if (identifier !== undefined) {
            if (!/\p{L}/u.test(identifier) || !/\d/u.test(identifier)) return identifier;
            const quantity = /^[+-]?\d/u.test(identifier);
            const spans = quantity ? new RegExp("[-+]?" + numeric + "|(?<=\\d)[.,](?=\\d)", "gu")
                : /\d+|(?<=\d)[.,](?=\d)/gu;
            const parts = [];
            let at = 0;
            for (const match of identifier.matchAll(spans)) {
                if (match.index > at) parts.push(identifier.slice(at, match.index));
                const digits = match[0];
                if (digits === "." || digits === ",")
                    parts.push(digits === "." ? (code === "en" ? "point" : "punto") : (code === "en" ? "comma" : "coma"));
                else {
                    note("number");
                    parts.push(quantity ? number(digits, code) : [...digits].map(digit => SMALL[code][Number(digit)]).join(" "));
                }
                at = match.index + digits.length;
            }
            if (at < identifier.length) parts.push(identifier.slice(at));
            return parts.join(" ");
        }
        note("number");
        const chosen = currency || unit;
        let spoken = number(amount, code);
        if (chosen) {
            note("unit");
            const canonical = amount.replace(code === "en" ? /,/g : /\./g, "").replace(",", ".");
            const singular = Math.abs(Number(canonical)) === 1;
            if (code === "es" && chosen !== "%") spoken = spanishAgreement(spoken, chosen === "h");
            spoken += " " + UNITS[chosen][code === "en" ? 0 : 1][singular ? 0 : 1];
            if (rate !== undefined) {
                note("unit");
                spoken += (code === "en" ? " per " : " por ") + UNITS[rate][code === "en" ? 0 : 1][0];
            }
        }
        return spoken;
    });
}

module.exports = { languageCode, expand };
