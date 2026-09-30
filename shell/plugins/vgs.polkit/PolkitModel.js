.pragma library

// Pure decisions for vgs.polkit: what the prompt draws from the polkit
// agent's authentication flow, and the agent status the service publishes.
// QML owns the agent, the surfaces and the password text; the password never
// passes through here.

var DEFAULT_TITLE = "Authentication required";
var DEFAULT_PROMPT = "Password";
var FAILED_NOTE = "Authentication failed. Try again.";

// pkexec's message, `Authentication is needed to run `<program>' as the
// super user`, names the program; the title names it too. Any other
// action's message stands as it is under the default title.
var PKEXEC_MESSAGE = /^Authentication is (?:needed|required) to run [`']([^`']+)[`'] as /i;

function titleOf(message) {
    var match = PKEXEC_MESSAGE.exec(String(message || ""));
    return match ? "Authorize running " + match[1] : DEFAULT_TITLE;
}

// The PAM prompt without its trailing colon, `Password: ` reading
// `Password`; the default when PAM asked with no text.
function promptOf(inputPrompt) {
    var text = String(inputPrompt || "").replace(/[\s:]+$/, "");
    return text === "" ? DEFAULT_PROMPT : text;
}

// The identity the flow authenticates as: a user's display name, else its
// login name, or `Group <name>` for a group; "" for none.
function identityOf(identity) {
    if (identity === null || identity === undefined) return "";
    var name = String(identity.string || "");
    if (identity.isGroup === true) return name === "" ? "" : "Group " + name;
    var display = String(identity.displayName || "");
    return display !== "" ? display : name;
}

// Every identity FLOW offers, labelled as identityOf labels one, in the
// flow's order; the prompt offers a choice when there are several.
function identitiesOf(flow) {
    var list = flow.identities;
    if (list === null || list === undefined || typeof list.length !== "number") return [];
    var out = [];
    for (var i = 0; i < list.length; i++) out.push(identityOf(list[i]));
    return out;
}

// The index of FLOW's selected identity among its identities, -1 for none.
function identityIndexOf(flow) {
    var list = flow.identities;
    if (list === null || list === undefined || typeof list.length !== "number") return -1;
    for (var i = 0; i < list.length; i++) if (list[i] === flow.selectedIdentity) return i;
    return -1;
}

// The line under the field: PAM's own message, an error or not, else the
// failed note once an attempt failed, else null.
function noteOf(flow) {
    var text = String(flow.supplementaryMessage || "");
    if (text !== "") return { text: text, tone: flow.supplementaryIsError === true ? "danger" : "info" };
    if (flow.failed === true) return { text: FAILED_NOTE, tone: "danger" };
    return null;
}

// What the prompt draws for FLOW, the agent's AuthFlow or a plain object
// with its properties; null while no flow is live. `inputEnabled` holds
// while PAM waits for a response, `waiting` while PAM works on one or has
// not asked yet, so the accept action and the field answer only when a
// response is wanted.
function viewOf(flow) {
    if (flow === null || flow === undefined) return null;
    var required = flow.isResponseRequired === true;
    return {
        title: titleOf(flow.message),
        message: String(flow.message || ""),
        action: String(flow.actionId || ""),
        identity: identityOf(flow.selectedIdentity),
        identities: identitiesOf(flow),
        identityIndex: identityIndexOf(flow),
        prompt: promptOf(flow.inputPrompt),
        echo: flow.responseVisible === true,
        inputEnabled: required,
        waiting: !required,
        note: noteOf(flow)
    };
}

// The `agent` status value: whether polkitd accepted the agent. polkitd
// takes one agent per session, so another agent registered first, or no
// polkitd, leaves it unregistered.
function agentStatus(registered) {
    if (registered === true) return { tone: "ok", text: "Registered with polkitd: authentication prompts show here" };
    return { tone: "warning", text: "Not registered with polkitd: another polkit agent holds this session, or polkitd is not running" };
}

// Whether NEXT, an agentStatus value or null, differs from PREVIOUS, the
// value last published or null; a new shell object or a rebuilt binding
// that yields the same state publishes nothing.
function statusChanged(previous, next) {
    if (next === null) return false;
    return previous === null || previous.tone !== next.tone || previous.text !== next.text;
}

// Whether closing the prompt must cancel FLOW: a live flow that neither
// completed nor was cancelled. A second cancel of one request is refused.
function cancellable(flow) {
    return flow !== null && flow !== undefined && flow.isCompleted !== true && flow.isCancelled !== true;
}
