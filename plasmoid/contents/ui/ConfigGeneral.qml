import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15 as Controls
import org.kde.kirigami 2.20 as Kirigami

Item {
    id: root
    implicitWidth: scrollView.implicitWidth
    implicitHeight: 500

    // ── General ──────────────────────────────────────────────────────────────
    property alias cfg_updateIntervalMs:  updateIntervalSlider.value
    property alias cfg_processLimit:      processLimitSpin.value

    // ── Sections ─────────────────────────────────────────────────────────────
    property alias cfg_showCpu:       showCpuCheck.checked
    property alias cfg_showRam:       showRamCheck.checked
    property alias cfg_showGpu:       showGpuCheck.checked
    property alias cfg_showDisk:      showDiskCheck.checked
    property alias cfg_showNetwork:   showNetworkCheck.checked
    property alias cfg_showProcesses: showProcessesCheck.checked
    property alias cfg_showBattery:   showBatteryCheck.checked

    // ── Per-section average periods ───────────────────────────────────────────
    property alias cfg_ramPeriod1Days:   ramP1.value
    property alias cfg_ramPeriod2Days:   ramP2.value
    property alias cfg_swapPeriod1Days:  swapP1.value
    property alias cfg_swapPeriod2Days:  swapP2.value
    property alias cfg_gpuPeriod1Days:   gpuP1.value
    property alias cfg_gpuPeriod2Days:   gpuP2.value
    property alias cfg_vramPeriod1Days:  vramP1.value
    property alias cfg_vramPeriod2Days:  vramP2.value
    property alias cfg_netDlPeriod1Days: netDlP1.value
    property alias cfg_netDlPeriod2Days: netDlP2.value
    property alias cfg_netUlPeriod1Days: netUlP1.value
    property alias cfg_netUlPeriod2Days: netUlP2.value

    Controls.ScrollView {
        id: scrollView
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        Kirigami.FormLayout {
            id: form
            width: scrollView.availableWidth

            // ── Update ─────────────────────────────────────────────────────────
            Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Update" }

            RowLayout {
                Kirigami.FormData.label: "Interval: " + (updateIntervalSlider.value / 1000).toFixed(1) + " s"
                Controls.Slider {
                    id: updateIntervalSlider
                    from: 1000; to: 10000; stepSize: 500
                    implicitWidth: 200
                }
            }

            Controls.SpinBox {
                id: processLimitSpin
                Kirigami.FormData.label: "Process list length"
                from: 3; to: 20
            }

            // ── Sections ───────────────────────────────────────────────────────
            Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Visible sections" }

            Controls.CheckBox { id: showCpuCheck;       Kirigami.FormData.label: "CPU" }
            Controls.CheckBox { id: showRamCheck;       Kirigami.FormData.label: "RAM" }
            Controls.CheckBox { id: showGpuCheck;       Kirigami.FormData.label: "GPU" }
            Controls.CheckBox { id: showDiskCheck;      Kirigami.FormData.label: "Disk" }
            Controls.CheckBox { id: showNetworkCheck;   Kirigami.FormData.label: "Network" }
            Controls.CheckBox { id: showProcessesCheck; Kirigami.FormData.label: "Processes" }
            Controls.CheckBox { id: showBatteryCheck;   Kirigami.FormData.label: "Battery" }

            // ── Average periods ────────────────────────────────────────────────
            Kirigami.Separator { Kirigami.FormData.isSection: true; Kirigami.FormData.label: "Usage average periods" }

            // RAM
            Kirigami.Separator { Kirigami.FormData.label: "RAM" }
            Controls.SpinBox { id: ramP1;  Kirigami.FormData.label: "Short window (days)"; from: 1; to: 365 }
            Controls.SpinBox { id: ramP2;  Kirigami.FormData.label: "Long window (days)";  from: 1; to: 365 }

            // Swap
            Kirigami.Separator { Kirigami.FormData.label: "Swap" }
            Controls.SpinBox { id: swapP1; Kirigami.FormData.label: "Short window (days)"; from: 1; to: 365 }
            Controls.SpinBox { id: swapP2; Kirigami.FormData.label: "Long window (days)";  from: 1; to: 365 }

            // GPU
            Kirigami.Separator { Kirigami.FormData.label: "GPU" }
            Controls.SpinBox { id: gpuP1;  Kirigami.FormData.label: "Short window (days)"; from: 1; to: 365 }
            Controls.SpinBox { id: gpuP2;  Kirigami.FormData.label: "Long window (days)";  from: 1; to: 365 }

            // VRAM
            Kirigami.Separator { Kirigami.FormData.label: "VRAM" }
            Controls.SpinBox { id: vramP1; Kirigami.FormData.label: "Short window (days)"; from: 1; to: 365 }
            Controls.SpinBox { id: vramP2; Kirigami.FormData.label: "Long window (days)";  from: 1; to: 365 }

            // Network download
            Kirigami.Separator { Kirigami.FormData.label: "Network download" }
            Controls.SpinBox { id: netDlP1; Kirigami.FormData.label: "Short window (days)"; from: 1; to: 365 }
            Controls.SpinBox { id: netDlP2; Kirigami.FormData.label: "Long window (days)";  from: 1; to: 365 }

            // Network upload
            Kirigami.Separator { Kirigami.FormData.label: "Network upload" }
            Controls.SpinBox { id: netUlP1; Kirigami.FormData.label: "Short window (days)"; from: 1; to: 365 }
            Controls.SpinBox { id: netUlP2; Kirigami.FormData.label: "Long window (days)";  from: 1; to: 365 }
        }
    }
}
