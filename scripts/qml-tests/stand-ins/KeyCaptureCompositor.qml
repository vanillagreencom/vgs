pragma Singleton
import QtQml

// The Compositor calls KeyCapture makes, recorded: each pass-through verb
// it sends, with the callback that takes its answer, which a test answers
// by hand; `refuse`, when set, is the answer a pass-through request gets at
// once, as a refused request does.
QtObject {
    property var requests: []
    property var answers: []
    property string refuse: ""

    function passthrough(verb, done) {
        requests = requests.concat([verb]);
        if (refuse !== "") return refuse;
        answers = answers.concat([done]);
        return "ok";
    }

    // The answer REPLY for the request at INDEX of `requests`, once.
    function answer(index, reply) {
        const done = answers[index];
        answers[index] = null;
        done(reply);
    }

    // `ok` for every request not answered yet, oldest first.
    function answerAll() {
        for (let i = 0; i < answers.length; i++)
            if (answers[i] !== null) answer(i, "ok");
    }

    function reset() {
        requests = [];
        answers = [];
        refuse = "";
    }
}
