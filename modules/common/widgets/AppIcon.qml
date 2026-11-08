import QtQuick
import org.kde.kirigami as Kirigami
import qs.services
import qs.modules.common

Kirigami.Icon {
    id: root
    
    property real implicitSize: 26
    implicitWidth: Math.round(implicitSize)
    implicitHeight: Math.round(implicitSize)
    width: implicitWidth
    height: implicitHeight

    roundToIconSize: false
    animated: true // It's just fading from one icon to another
}
