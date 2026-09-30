import QtQuick
import qs.Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel

// The polkit prompt: a scrim over the screen and one dialog asking for the
// response the agent's authentication flow wants, usually the password. It
// names the action that asks, by its message and its polkit action id, and
// the identity it authenticates as; with several identities, such as the
// members of an administrators' group, a choice selects another, which
// starts the conversation again as that identity. The service summons it when a request
// starts and hides it when the request ends; a summon with no request live
// throws, so the host refuses it and no prompt shows without a flow.
//
// Authenticate and Enter submit the field once PAM asks; the field and the
// action wait while PAM works. Cancel, Escape and the prompt closing by any
// other path, a hide or the plugin disabled, cancel the live request. The
// password lives only in the field: it is cleared on submit and on close,
// and is never logged, published or held anywhere else.
Item {
    id: root

    // The core assigns the plugin's scoped shell object after creation.
    property var shell: null
    readonly property var agent: shell === null ? null : shell.polkit.agent
    readonly property var flow: agent === null ? null : agent.flow
    readonly property var view: PolkitModel.viewOf(flow)

    function open(payloadJson) {
        if (flow === null) throw new Error("polkit: refused: flow=none");
        secret.text = "";
        Qt.callLater(() => dialog.forceActiveFocus());
    }

    function close() {
        secret.text = "";
        cancel();
    }

    function cancel() {
        if (PolkitModel.cancellable(flow)) flow.cancelAuthenticationRequest();
    }

    function submit() {
        if (flow === null || !flow.isResponseRequired) return;
        const response = secret.text;
        secret.text = "";
        flow.submit(response);
    }

    // Authenticate as the flow's identity at INDEX; the flow starts its
    // conversation again, so the field is cleared.
    function selectIdentity(index) {
        if (flow === null || index < 0 || index >= flow.identities.length || flow.identities[index] === flow.selectedIdentity) return;
        secret.text = "";
        flow.selectedIdentity = flow.identities[index];
    }

    // PAM asks again after a failed attempt: the field takes the focus back.
    Connections {
        target: root.flow
        function onIsResponseRequiredChanged() {
            if (root.flow !== null && root.flow.isResponseRequired) Qt.callLater(() => dialog.takeFocus());
        }
    }

    Scrim {
        onClicked: dialog.takeFocus()
    }

    Dialog {
        id: dialog
        anchors.centerIn: parent
        title: root.view === null ? "" : root.view.title
        message: root.view === null ? "" : root.view.message
        initialFocus: secret
        tabItems: [identityChoice, secret]
        actions: [
            { label: "Cancel", role: "cancel" },
            { label: "Authenticate", role: "accept", enabled: root.view !== null && root.view.inputEnabled }
        ]
        onAccepted: root.submit()
        onRejected: root.cancel()

        Label {
            role: "code"
            width: parent.width
            elide: Text.ElideMiddle
            color: Theme.color.textMuted
            visible: text !== ""
            text: root.view === null ? "" : root.view.action
        }

        Field {
            width: parent.width
            label: "Authenticate as"
            visible: root.view !== null && root.view.identities.length > 1

            Select {
                id: identityChoice
                width: parent.width
                model: root.view === null ? [] : root.view.identities
                currentIndex: root.view === null ? 0 : Math.max(0, root.view.identityIndex)
                // A choice writes the flow, then the control follows the
                // flow's selected identity again.
                onCurrentIndexChanged: {
                    root.selectIdentity(currentIndex);
                    currentIndex = Qt.binding(() => root.view === null ? 0 : Math.max(0, root.view.identityIndex));
                }
            }
        }

        Row {
            spacing: Theme.space.sm
            visible: root.view !== null && root.view.identity !== "" && root.view.identities.length <= 1
            Icon {
                name: "user"
                size: Theme.icon.size.sm
                color: Theme.color.textMuted
                anchors.verticalCenter: parent.verticalCenter
            }
            Label {
                role: "hint"
                text: root.view === null ? "" : root.view.identity
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        Field {
            width: parent.width
            label: root.view === null ? "" : root.view.prompt
            hint: root.view !== null && root.view.note !== null && root.view.note.tone === "info" ? root.view.note.text : ""
            error: root.view !== null && root.view.note !== null && root.view.note.tone === "danger" ? root.view.note.text : ""

            TextField {
                id: secret
                width: parent.width
                leadingIcon: "key-round"
                echoMode: root.view !== null && root.view.echo ? TextInput.Normal : TextInput.Password
                enabled: root.view !== null && root.view.inputEnabled
                error: root.view !== null && root.view.note !== null && root.view.note.tone === "danger"
            }
        }

        Row {
            spacing: Theme.space.sm
            visible: root.view !== null && root.view.waiting
            Spinner {
                anchors.verticalCenter: parent.verticalCenter
            }
            Label {
                role: "hint"
                text: "Checking"
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }
}
