.pragma library

// The one judge of a manager or surface reply: `ok`, or `ok <detail>` such
// as `ok hidden=<ids>`, is success; every other reply is a refusal to show.
function isOk(reply) {
    return reply === "ok" || reply.indexOf("ok ") === 0;
}
