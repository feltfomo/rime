import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    PanelWindow {
        anchors {
            top: true
            left: true
            right: true
        }

        implicitHeight: 64
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            color: "white"
            text: Quickshell.env("RIME_CRASH_REASON")
        }

        Item {
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: parent.verticalCenter
            width: reloadLabel.implicitWidth
            height: reloadLabel.implicitHeight

            Text {
                id: reloadLabel
                color: "white"
                text: "reload"
            }

            TapHandler {
                onTapped: Qt.quit()
            }
        }
    }
}
