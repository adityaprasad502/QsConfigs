import QtQuick

Rectangle {
    property double diameter

    implicitWidth: diameter
    implicitHeight: diameter
    width: implicitWidth
    height: implicitHeight
    radius: diameter / 2
}
