/* KratosOS installer slideshow (Calamares slideshow API 2). */
import QtQuick 2.0;
import calamares.slideshow 1.0;

Presentation
{
    id: presentation

    Slide {
        Image {
            id: background1
            source: "slide1.png"
            width: 560; height: 336
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
        }
        Text {
            anchors.horizontalCenter: background1.horizontalCenter
            anchors.top: background1.bottom
            anchors.topMargin: 12
            text: qsTr("Installing KratosOS.<br/>" +
                  "Your disk is being encrypted and the system copied. " +
                  "This takes a while; the computer does not need to be online.")
            wrapMode: Text.WordWrap
            width: 600
            horizontalAlignment: Text.Center
        }
    }
}
