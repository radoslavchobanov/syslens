import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15 as Controls

import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support 2.0 as P5Support
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.components 3.0 as PlasmaComponents3

PlasmoidItem {
    id: root

    readonly property url monitorIcon: Qt.resolvedUrl("../images/syslens.svg")
    readonly property string backendPath: decodeURIComponent(String(Qt.resolvedUrl("../code/backend.py")).replace(/^file:\/\//, ""))
    property string backendCommand: "python3 \"" + backendPath + "\" --json --sample-window 0.25"
        + " --process-limit "    + Plasmoid.configuration.processLimit
        + " --ram-period1-days " + Plasmoid.configuration.ramPeriod1Days
        + " --ram-period2-days " + Plasmoid.configuration.ramPeriod2Days
        + " --swap-period1-days " + Plasmoid.configuration.swapPeriod1Days
        + " --swap-period2-days " + Plasmoid.configuration.swapPeriod2Days
        + " --gpu-period1-days " + Plasmoid.configuration.gpuPeriod1Days
        + " --gpu-period2-days " + Plasmoid.configuration.gpuPeriod2Days
        + " --vram-period1-days " + Plasmoid.configuration.vramPeriod1Days
        + " --vram-period2-days " + Plasmoid.configuration.vramPeriod2Days
        + " --net-dl-period1-days " + Plasmoid.configuration.netDlPeriod1Days
        + " --net-dl-period2-days " + Plasmoid.configuration.netDlPeriod2Days
        + " --net-ul-period1-days " + Plasmoid.configuration.netUlPeriod1Days
        + " --net-ul-period2-days " + Plasmoid.configuration.netUlPeriod2Days
    readonly property color panelBg: "#11161a"
    readonly property color panelBorder: "#273942"
    readonly property color textPrimary: "#d7e2e4"
    readonly property color textSecondary: "#7d9299"
    readonly property color cyan: "#38BDF8"    // CPU
    readonly property color green: "#34D399"   // Memory
    readonly property color violet: "#A78BFA"  // GPU
    readonly property color amber: "#FBBF24"   // Disk
    readonly property color teal: "#2DD4BF"    // Network
    readonly property color coral: "#FB923C"   // Processes
    readonly property color red: "#F87171"     // semantic: danger/heat marker
    readonly property color battery: "#A3E635"  // Battery
    readonly property color chartSec: "#6B9AB8" // secondary chart series
    readonly property color gridLine: "#223139"

    property var snapshot: ({})
    property var cpuHistory: []
    property var memoryHistory: []
    property var diskReadHistory: []
    property var diskWriteHistory: []
    property var netDownHistory: []
    property var netUpHistory: []
    property string backendStatus: "waiting"
    property int historyLimit: 48
    property real maxNetDown: 1024
    property real maxNetUp: 1024
    property real maxCpuPower: 1.0

    Layout.preferredWidth: 720
    Layout.preferredHeight: 880
    Plasmoid.backgroundHints: PlasmaCore.Types.ConfigurableBackground
    Plasmoid.icon: monitorIcon
    Plasmoid.status: PlasmaCore.Types.ActiveStatus
    preferredRepresentation: Plasmoid.formFactor === PlasmaCore.Types.Planar ? fullRepresentation : null
    toolTipMainText: "SysLens"
    toolTipSubText: backendStatus

    Plasmoid.onActivated: {
        root.expanded = true;
    }

    function section(path, fallback) {
        var value = snapshot;
        for (var i = 0; i < path.length; i++) {
            if (value === undefined || value === null || value[path[i]] === undefined || value[path[i]] === null) {
                return fallback;
            }
            value = value[path[i]];
        }
        return value;
    }

    function percent(path) {
        var value = Number(section(path, 0));
        if (!isFinite(value)) {
            return 0;
        }
        return Math.max(0, Math.min(100, value));
    }

    function appendHistory(name, value) {
        var arr = root[name].slice(0);
        arr.push(Number(value) || 0);
        while (arr.length > historyLimit) {
            arr.shift();
        }
        root[name] = arr;
    }

    function ingest(output) {
        if (!output || output.length === 0) {
            backendStatus = "backend returned no output";
            return;
        }
        try {
            snapshot = JSON.parse(output);
            backendStatus = "updated " + Qt.formatTime(new Date(), "HH:mm:ss");
            appendHistory("cpuHistory", percent(["cpu", "usage_percent"]));
            appendHistory("memoryHistory", percent(["memory", "usage_percent"]));
            appendHistory("diskReadHistory", section(["disk", "total_read_bytes_per_sec"], 0));
            appendHistory("diskWriteHistory", section(["disk", "total_write_bytes_per_sec"], 0));
            appendHistory("netDownHistory", section(["network", "download_bytes_per_sec"], 0));
            appendHistory("netUpHistory", section(["network", "upload_bytes_per_sec"], 0));
            var dl = section(["network", "download_bytes_per_sec"], 0) || 0
            var ul = section(["network", "upload_bytes_per_sec"], 0) || 0
            if (dl > 0) root.maxNetDown = Math.max(root.maxNetDown, dl)
            if (ul > 0) root.maxNetUp = Math.max(root.maxNetUp, ul)
            var pw = section(["cpu", "power_watts"], 0) || 0
            if (pw > 0) root.maxCpuPower = Math.max(root.maxCpuPower, pw)
        } catch (error) {
            backendStatus = "json parse failed: " + error;
        }
    }

    function outputFromData(data) {
        if (!data) {
            return "";
        }
        var keys = ["stdout", "Stdout", "output", "Output", "value", "Value"];
        for (var i = 0; i < keys.length; i++) {
            if (data[keys[i]] !== undefined && data[keys[i]] !== null) {
                return String(data[keys[i]]).trim();
            }
        }
        if (data["exit code"] !== undefined || data["exitCode"] !== undefined) {
            return "";
        }
        return String(data).trim();
    }

    function bytes(value, suffix) {
        var amount = Number(value) || 0;
        var units = suffix ? ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"] : ["B", "KB", "MB", "GB", "TB"];
        var index = 0;
        while (amount >= 1024 && index < units.length - 1) {
            amount /= 1024;
            index++;
        }
        var precision = amount >= 100 || index === 0 ? 0 : 1;
        return amount.toFixed(precision) + " " + units[index];
    }

    function fixed(value, decimals, fallback) {
        var numeric = Number(value);
        if (!isFinite(numeric)) {
            return fallback || "n/a";
        }
        return numeric.toFixed(decimals);
    }

    function firstAvailable(list, key, fallback) {
        if (!list || list.length === 0) {
            return fallback;
        }
        for (var i = 0; i < list.length; i++) {
            if (list[i][key] !== undefined && list[i][key] !== null) {
                return list[i][key];
            }
        }
        return fallback;
    }

    function joinNames(list, key, limit) {
        if (!list || list.length === 0) {
            return "none";
        }
        var names = [];
        for (var i = 0; i < Math.min(list.length, limit); i++) {
            names.push(list[i][key]);
        }
        if (list.length > limit) {
            names.push("+" + (list.length - limit));
        }
        return names.join(", ");
    }

    function firstPowerWatts() {
        var supplies = section(["power", "supplies"], []);
        for (var i = 0; i < supplies.length; i++) {
            if (supplies[i].power_watts !== undefined && supplies[i].power_watts !== null) {
                return supplies[i].name + "  " + fixed(supplies[i].power_watts, 2, "n/a") + " W";
            }
        }
        var rapl = section(["power", "rapl"], []);
        if (rapl.length > 0) {
            return rapl[0].name + "  " + fixed(rapl[0].power_watts, 2, "n/a") + " W";
        }
        return "not exposed";
    }

    function tempText() {
        return section(["temperature", "cpu_current_celsius"], null) === null ? "n/a" : fixed(section(["temperature", "cpu_current_celsius"], 0), 1, "n/a") + " C";
    }

    function tempAverageText() {
        return section(["temperature", "cpu_average_celsius"], null) === null ? "n/a" : fixed(section(["temperature", "cpu_average_celsius"], 0), 1, "n/a") + " C";
    }

    function tempMaximumText() {
        return section(["temperature", "cpu_maximum_celsius"], null) === null ? "n/a" : fixed(section(["temperature", "cpu_maximum_celsius"], 0), 1, "n/a") + " C";
    }

    function cpuPowerText() {
        var watts = section(["cpu", "power_watts"], null);
        return watts === null ? "n/a" : fixed(watts, 2, "n/a") + " W";
    }

    function cpuAverageText(period) {
        var value = section(["cpu", "usage_average_percent", period], null);
        return value === null ? "n/a" : fixed(value, 1, "n/a") + "%";
    }

    function gpuDevice() {
        var devices = section(["gpu", "devices"], []);
        return devices.length > 0 ? devices[0] : {};
    }

    function networkPeriodText(period) {
        var item = section(["network", "totals", period], null);
        if (item === null) {
            return "n/a";
        }
        return "D " + bytes(item.rx_bytes || 0, false) + " / U " + bytes(item.tx_bytes || 0, false);
    }

    function ipText(path) {
        var value = section(path, null);
        return value === null || value === "" ? "n/a" : value;
    }

    function periodLabel(days) {
        if (days === 1) return "1D"
        if (days % 365 === 0) return (days / 365) + "Y"
        if (days % 30 === 0) return (days / 30) + "MO"
        if (days % 7 === 0) return (days / 7) + "W"
        return days + "D"
    }

    function metricAvgText(basePath, periodKey) {
        var value = section(basePath.concat([periodKey]), null)
        return value === null ? "n/a" : fixed(value, 1, "n/a") + "%"
    }

    function netAvgBytesText(metricPath, periodKey) {
        var value = section(metricPath.concat([periodKey]), null)
        return value === null ? "n/a" : bytes(value, true)
    }

    P5Support.DataSource {
        id: executableSource
        engine: "executable"
        connectedSources: [root.backendCommand]
        interval: Plasmoid.configuration.updateIntervalMs

        onNewData: function(sourceName, data) {
            root.ingest(root.outputFromData(data));
        }

        onDataChanged: {
            if (data[root.backendCommand]) {
                root.ingest(root.outputFromData(data[root.backendCommand]));
            }
        }

    }

    compactRepresentation: MouseArea {
        property bool wasExpanded: false

        implicitWidth: height
        Layout.minimumWidth: height
        Layout.maximumWidth: height

        activeFocusOnTab: true
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton

        Accessible.name: Plasmoid.title
        Accessible.role: Accessible.Button

        onPressed: wasExpanded = root.expanded
        onClicked: root.expanded = !wasExpanded

        Kirigami.Icon {
            id: trayIcon
            anchors.fill: parent
            source: root.monitorIcon
            active: parent.containsMouse || root.expanded
        }
    }

    fullRepresentation: Item {
        implicitWidth: 720
        implicitHeight: 880
        Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        Layout.minimumHeight: Kirigami.Units.gridUnit * 28
        Layout.preferredWidth: 720
        Layout.preferredHeight: 880

        Rectangle {
            anchors.fill: parent
            color: "#d0000000"
            border.color: "#243238"
            border.width: 1
        }

        Controls.ScrollView {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            clip: true

            ColumnLayout {
                width: Math.max(Kirigami.Units.gridUnit * 30, parent.width - Kirigami.Units.largeSpacing)
                spacing: Kirigami.Units.smallSpacing

                HeaderBlock {
                    Layout.fillWidth: true
                    title: "SysLens"
                    subtitle: root.section(["uptime", "hostname"], "host") + "  " + root.section(["uptime", "kernel"], "kernel") + "  " + root.backendStatus
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: width > Kirigami.Units.gridUnit * 42 ? 2 : 1
                    columnSpacing: Kirigami.Units.smallSpacing
                    rowSpacing: Kirigami.Units.smallSpacing

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 25
                        title: "CPU"
                        accent: root.cyan
                        visible: Plasmoid.configuration.showCpu
                        available: root.section(["cpu", "available"], false)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: Kirigami.Units.smallSpacing

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: Kirigami.Units.largeSpacing

                                DonutChart {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                                    Layout.alignment: Qt.AlignVCenter
                                    value: root.percent(["cpu", "usage_percent"])
                                    accent: root.cyan
                                    label: fixed(root.percent(["cpu", "usage_percent"]), 0, "0") + "%"
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Kirigami.Units.smallSpacing
                                        DonutChart {
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4.2
                                            Layout.preferredHeight: Kirigami.Units.gridUnit * 4.2
                                            value: root.maxCpuPower > 0
                                                ? Math.min(100, (root.section(["cpu", "power_watts"], 0) / root.maxCpuPower) * 100)
                                                : 0
                                            accent: root.cyan
                                            label: root.fixed(root.section(["cpu", "power_watts"], 0), 0, "0") + "W"
                                            small: true
                                        }
                                        MetricLine {
                                            Layout.fillWidth: true
                                            label: "Power"
                                            value: root.cpuPowerText()
                                        }
                                    }
                                    MetricLine { label: "Model"; value: root.section(["cpu", "model"], "unknown") }
                                    MetricLine { label: "Cores"; value: root.section(["cpu", "physical_cores"], "n/a") + " physical / " + root.section(["cpu", "logical_cores"], "n/a") + " threads" }
                                    MetricLine { label: "Clock"; value: root.fixed(root.section(["cpu", "current_mhz_avg"], 0), 0, "n/a") + " MHz avg  " + root.fixed(root.section(["cpu", "current_mhz_max"], 0), 0, "n/a") + " MHz peak" }
                                    MetricLine { label: "Limits"; value: root.fixed(root.section(["cpu", "cpufreq", "scaling_min_mhz"], 0), 0, "n/a") + " - " + root.fixed(root.section(["cpu", "cpufreq", "scaling_max_mhz"], 0), 0, "n/a") + " MHz" }
                                    MetricLine { label: "Boost"; value: root.section(["cpu", "cpufreq", "boost"], []).join(", ") || "n/a" }
                                    MetricLine { label: "Governor"; value: root.section(["cpu", "cpufreq", "governors"], []).join(", ") || "n/a" }
                                }
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "CPU temperature"
                                values: [
                                    root.section(["temperature", "cpu_current_celsius"], 0),
                                    root.section(["temperature", "cpu_average_celsius"], 0),
                                    root.section(["temperature", "cpu_maximum_celsius"], 0)
                                ]
                                labels: ["NOW " + root.tempText(), "AVG " + root.tempAverageText(), "MAX " + root.tempMaximumText()]
                                markerColors: [root.textPrimary, root.cyan, root.red]
                                accent: root.cyan
                                maxValue: 100
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "CPU usage average"
                                values: [
                                    root.section(["cpu", "usage_average_percent", "1d"], 0),
                                    root.section(["cpu", "usage_average_percent", "1mo"], 0),
                                    root.section(["cpu", "usage_average_percent", "overall"], 0)
                                ]
                                labels: ["1D " + root.cpuAverageText("1d"), "1MO " + root.cpuAverageText("1mo"), "ALL " + root.cpuAverageText("overall")]
                                markerColors: [root.textPrimary, root.cyan, root.red]
                                accent: root.cyan
                                maxValue: 100
                            }
                        }
                    }

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 27
                        title: "RAM"
                        accent: root.green
                        visible: Plasmoid.configuration.showRam
                        available: root.section(["memory", "available"], false)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: Kirigami.Units.smallSpacing

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: Kirigami.Units.largeSpacing

                                DonutChart {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                                    Layout.alignment: Qt.AlignVCenter
                                    value: root.percent(["memory", "usage_percent"])
                                    accent: root.green
                                    label: fixed(root.percent(["memory", "usage_percent"]), 0, "0") + "%"
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Kirigami.Units.smallSpacing
                                        DonutChart {
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4.2
                                            Layout.preferredHeight: Kirigami.Units.gridUnit * 4.2
                                            value: root.percent(["memory", "swap", "usage_percent"])
                                            accent: root.chartSec
                                            label: root.fixed(root.section(["memory", "swap", "usage_percent"], 0), 0, "0") + "%"
                                            small: true
                                        }
                                        MetricLine {
                                            Layout.fillWidth: true
                                            label: "Swap"
                                            value: root.bytes(root.section(["memory", "swap", "used_bytes"], 0), false) + " / " + root.bytes(root.section(["memory", "swap", "total_bytes"], 0), false)
                                        }
                                    }
                                    MetricLine { label: "Used"; value: root.bytes(root.section(["memory", "used_bytes"], 0), false) + " / " + root.bytes(root.section(["memory", "total_bytes"], 0), false) }
                                    MetricLine { label: "Available"; value: root.bytes(root.section(["memory", "available_bytes"], 0), false) }
                                    MetricLine { label: "Cache"; value: root.bytes(root.section(["memory", "cached_bytes"], 0), false) + " cache  " + root.bytes(root.section(["memory", "buffers_bytes"], 0), false) + " buffers" }
                                    RamBreakdownBar {
                                        Layout.fillWidth: true
                                        Layout.preferredHeight: Kirigami.Units.gridUnit * 2.2
                                        usedBytes: root.section(["memory", "used_bytes"], 0)
                                        cachedBytes: root.section(["memory", "cached_bytes"], 0) + root.section(["memory", "buffers_bytes"], 0)
                                        totalBytes: Math.max(1, root.section(["memory", "total_bytes"], 1))
                                    }
                                }
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "RAM usage average"
                                values: [
                                    root.section(["memory", "usage_average_percent", "period1"], 0),
                                    root.section(["memory", "usage_average_percent", "period2"], 0),
                                    root.section(["memory", "usage_average_percent", "overall"], 0)
                                ]
                                labels: [
                                    root.periodLabel(Plasmoid.configuration.ramPeriod1Days) + " " + root.metricAvgText(["memory", "usage_average_percent"], "period1"),
                                    root.periodLabel(Plasmoid.configuration.ramPeriod2Days) + " " + root.metricAvgText(["memory", "usage_average_percent"], "period2"),
                                    "ALL " + root.metricAvgText(["memory", "usage_average_percent"], "overall")
                                ]
                                markerColors: [root.textPrimary, root.green, root.red]
                                accent: root.green
                                maxValue: 100
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "Swap usage average"
                                values: [
                                    root.section(["memory", "swap", "usage_average_percent", "period1"], 0),
                                    root.section(["memory", "swap", "usage_average_percent", "period2"], 0),
                                    root.section(["memory", "swap", "usage_average_percent", "overall"], 0)
                                ]
                                labels: [
                                    root.periodLabel(Plasmoid.configuration.swapPeriod1Days) + " " + root.metricAvgText(["memory", "swap", "usage_average_percent"], "period1"),
                                    root.periodLabel(Plasmoid.configuration.swapPeriod2Days) + " " + root.metricAvgText(["memory", "swap", "usage_average_percent"], "period2"),
                                    "ALL " + root.metricAvgText(["memory", "swap", "usage_average_percent"], "overall")
                                ]
                                markerColors: [root.textPrimary, root.chartSec, root.chartSec]
                                accent: root.chartSec
                                maxValue: 100
                            }
                        }
                    }

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 25
                        title: "GPU"
                        accent: root.violet
                        visible: Plasmoid.configuration.showGpu
                        available: root.section(["gpu", "available"], false)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: Kirigami.Units.smallSpacing

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                spacing: Kirigami.Units.largeSpacing
                                DonutChart {
                                    Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                    Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                                    Layout.alignment: Qt.AlignVCenter
                                    value: Number(root.gpuDevice().usage_percent || 0)
                                    accent: root.violet
                                    label: root.fixed(root.gpuDevice().usage_percent || 0, 0, "0") + "%"
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Kirigami.Units.smallSpacing
                                        DonutChart {
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 4.2
                                            Layout.preferredHeight: Kirigami.Units.gridUnit * 4.2
                                            value: Number(root.gpuDevice().vram_usage_percent || 0)
                                            accent: root.chartSec
                                            label: root.fixed(root.gpuDevice().vram_usage_percent || 0, 0, "0") + "%"
                                            small: true
                                        }
                                        MetricLine {
                                            Layout.fillWidth: true
                                            label: "VRAM"
                                            value: root.bytes(root.gpuDevice().vram_used_bytes || 0, false) + " / " + root.bytes(root.gpuDevice().vram_total_bytes || 0, false)
                                        }
                                    }
                                    MetricLine { label: "Device"; value: root.gpuDevice().label || "not exposed" }
                                    MetricLine { label: "PCI"; value: (root.gpuDevice().vendor_id || "n/a") + " / " + (root.gpuDevice().device_id || "n/a") }
                                }
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "GPU usage average"
                                values: [
                                    root.section(["gpu", "usage_average_percent", "period1"], 0),
                                    root.section(["gpu", "usage_average_percent", "period2"], 0),
                                    root.section(["gpu", "usage_average_percent", "overall"], 0)
                                ]
                                labels: [
                                    root.periodLabel(Plasmoid.configuration.gpuPeriod1Days) + " " + root.metricAvgText(["gpu", "usage_average_percent"], "period1"),
                                    root.periodLabel(Plasmoid.configuration.gpuPeriod2Days) + " " + root.metricAvgText(["gpu", "usage_average_percent"], "period2"),
                                    "ALL " + root.metricAvgText(["gpu", "usage_average_percent"], "overall")
                                ]
                                markerColors: [root.textPrimary, root.violet, root.red]
                                accent: root.violet
                                maxValue: 100
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "VRAM usage average"
                                values: [
                                    root.section(["gpu", "vram_average_percent", "period1"], 0),
                                    root.section(["gpu", "vram_average_percent", "period2"], 0),
                                    root.section(["gpu", "vram_average_percent", "overall"], 0)
                                ]
                                labels: [
                                    root.periodLabel(Plasmoid.configuration.vramPeriod1Days) + " " + root.metricAvgText(["gpu", "vram_average_percent"], "period1"),
                                    root.periodLabel(Plasmoid.configuration.vramPeriod2Days) + " " + root.metricAvgText(["gpu", "vram_average_percent"], "period2"),
                                    "ALL " + root.metricAvgText(["gpu", "vram_average_percent"], "overall")
                                ]
                                markerColors: [root.textPrimary, root.chartSec, root.chartSec]
                                accent: root.chartSec
                                maxValue: 100
                            }
                        }
                    }

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 22
                        title: "Disk"
                        accent: root.amber
                        visible: Plasmoid.configuration.showDisk
                        available: root.section(["disk", "available"], false)

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: Kirigami.Units.largeSpacing
                            DonutChart {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                                Layout.alignment: Qt.AlignVCenter
                                value: root.percent(["disk", "root", "usage_percent"])
                                accent: root.amber
                                label: root.fixed(root.section(["disk", "root", "usage_percent"], 0), 0, "0") + "%"
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                MetricLine { label: "Root"; value: root.bytes(root.section(["disk", "root", "used_bytes"], 0), false) + " used / " + root.bytes(root.section(["disk", "root", "total_bytes"], 0), false) + " total" }
                                MetricLine { label: "Avail"; value: root.bytes(root.section(["disk", "root", "free_bytes"], 0), false) + " free  " + root.bytes(root.section(["disk", "root", "reserved_bytes"], 0), false) + " reserved" }
                                MetricLine { label: "I/O"; value: "R " + root.bytes(root.section(["disk", "total_read_bytes_per_sec"], 0), true) + "  W " + root.bytes(root.section(["disk", "total_write_bytes_per_sec"], 0), true) }
                                MetricLine { label: "Devices"; value: root.joinNames(root.section(["disk", "devices"], []), "name", 4) }
                                LineChart {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: Kirigami.Units.gridUnit * 7
                                    seriesA: root.diskReadHistory
                                    seriesB: root.diskWriteHistory
                                    accentA: root.amber
                                    accentB: root.chartSec
                                    maxValue: 0
                                    labelA: "READ"
                                    labelB: "WRITE"
                                    percentMode: false
                                }
                            }
                        }
                    }

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 31
                        title: "Network"
                        accent: root.teal
                        visible: Plasmoid.configuration.showNetwork
                        available: root.section(["network", "available"], false)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: Kirigami.Units.smallSpacing

                            // ── Live speed gauges + info ──────────────────────
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.largeSpacing

                                RowLayout {
                                    spacing: Kirigami.Units.smallSpacing

                                    ColumnLayout {
                                        spacing: 3
                                        DonutChart {
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                            Layout.preferredHeight: Kirigami.Units.gridUnit * 5
                                            value: root.maxNetDown > 0
                                                ? Math.min(100, (root.section(["network", "download_bytes_per_sec"], 0) / root.maxNetDown) * 100)
                                                : 0
                                            accent: root.teal
                                            label: "↓"
                                        }
                                        PlasmaComponents3.Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: root.bytes(root.section(["network", "download_bytes_per_sec"], 0), true)
                                            color: root.teal
                                            font.pixelSize: 10
                                            font.bold: true
                                        }
                                    }

                                    ColumnLayout {
                                        spacing: 3
                                        DonutChart {
                                            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
                                            Layout.preferredHeight: Kirigami.Units.gridUnit * 5
                                            value: root.maxNetUp > 0
                                                ? Math.min(100, (root.section(["network", "upload_bytes_per_sec"], 0) / root.maxNetUp) * 100)
                                                : 0
                                            accent: root.chartSec
                                            label: "↑"
                                        }
                                        PlasmaComponents3.Label {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: root.bytes(root.section(["network", "upload_bytes_per_sec"], 0), true)
                                            color: root.chartSec
                                            font.pixelSize: 10
                                            font.bold: true
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 4
                                    MetricLine { label: "Interfaces"; value: root.joinNames(root.section(["network", "interfaces"], []), "name", 5) + " / " + root.section(["network", "interface_count"], 0) + " total" }
                                    MetricLine { label: "Primary"; value: root.section(["network", "primary", "name"], "n/a") + "  " + root.section(["network", "primary", "state"], "") + "  drops " + root.section(["network", "primary", "drops"], 0) }
                                    MetricLine { label: "Local IP"; value: root.ipText(["network", "local_ipv4"]) }
                                    MetricLine { label: "Global IP"; value: root.ipText(["network", "global_ipv4", "address"]) }
                                }
                            }

                            // ── Period traffic totals ─────────────────────────
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing
                                NetworkPeriodTile {
                                    Layout.fillWidth: true
                                    period: "DAY"
                                    rxBytes: root.bytes(root.section(["network", "totals", "daily", "rx_bytes"], 0), false)
                                    txBytes: root.bytes(root.section(["network", "totals", "daily", "tx_bytes"], 0), false)
                                }
                                NetworkPeriodTile {
                                    Layout.fillWidth: true
                                    period: "WEEK"
                                    rxBytes: root.bytes(root.section(["network", "totals", "weekly", "rx_bytes"], 0), false)
                                    txBytes: root.bytes(root.section(["network", "totals", "weekly", "tx_bytes"], 0), false)
                                }
                                NetworkPeriodTile {
                                    Layout.fillWidth: true
                                    period: "MONTH"
                                    rxBytes: root.bytes(root.section(["network", "totals", "monthly", "rx_bytes"], 0), false)
                                    txBytes: root.bytes(root.section(["network", "totals", "monthly", "tx_bytes"], 0), false)
                                }
                            }

                            // ── Live traffic chart ────────────────────────────
                            LineChart {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 7
                                seriesA: root.netDownHistory
                                seriesB: root.netUpHistory
                                accentA: root.teal
                                accentB: root.chartSec
                                maxValue: 0
                                labelA: "DOWNLOAD"
                                labelB: "UPLOAD"
                                percentMode: false
                            }

                            // ── Average bars ──────────────────────────────────
                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "Download average"
                                values: [
                                    root.section(["network", "download_average", "period1"], 0),
                                    root.section(["network", "download_average", "period2"], 0),
                                    root.section(["network", "download_average", "overall"], 0)
                                ]
                                labels: [
                                    root.periodLabel(Plasmoid.configuration.netDlPeriod1Days) + " " + root.netAvgBytesText(["network", "download_average"], "period1"),
                                    root.periodLabel(Plasmoid.configuration.netDlPeriod2Days) + " " + root.netAvgBytesText(["network", "download_average"], "period2"),
                                    "ALL " + root.netAvgBytesText(["network", "download_average"], "overall")
                                ]
                                markerColors: [root.textPrimary, root.teal, root.red]
                                accent: root.teal
                                maxValue: 0
                            }

                            MarkerSummaryBar {
                                Layout.fillWidth: true
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 3.2
                                title: "Upload average"
                                values: [
                                    root.section(["network", "upload_average", "period1"], 0),
                                    root.section(["network", "upload_average", "period2"], 0),
                                    root.section(["network", "upload_average", "overall"], 0)
                                ]
                                labels: [
                                    root.periodLabel(Plasmoid.configuration.netUlPeriod1Days) + " " + root.netAvgBytesText(["network", "upload_average"], "period1"),
                                    root.periodLabel(Plasmoid.configuration.netUlPeriod2Days) + " " + root.netAvgBytesText(["network", "upload_average"], "period2"),
                                    "ALL " + root.netAvgBytesText(["network", "upload_average"], "overall")
                                ]
                                markerColors: [root.textPrimary, root.chartSec, root.red]
                                accent: root.chartSec
                                maxValue: 0
                            }
                        }
                    }

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.columnSpan: parent.columns
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 16
                        title: "Battery"
                        accent: root.battery
                        visible: Plasmoid.configuration.showBattery
                        available: root.section(["battery", "available"], false)

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: Kirigami.Units.largeSpacing

                            DonutChart {
                                Layout.preferredWidth: Kirigami.Units.gridUnit * 8
                                Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                                Layout.alignment: Qt.AlignVCenter
                                value: root.percent(["battery", "capacity_percent"])
                                accent: root.battery
                                label: root.fixed(root.section(["battery", "capacity_percent"], 0), 0, "0") + "%"
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4

                                MetricLine { label: "Status"; value: root.section(["battery", "status"], "n/a") || "n/a" }
                                MetricLine {
                                    label: "Power"
                                    value: {
                                        var w = root.section(["battery", "power_watts"], null)
                                        if (w === null) return "n/a"
                                        var st = root.section(["battery", "status"], "")
                                        var prefix = st === "Discharging" ? "−" : (st === "Charging" ? "+" : "")
                                        return prefix + root.fixed(w, 2, "n/a") + " W"
                                    }
                                }
                                MetricLine {
                                    label: "Energy"
                                    value: {
                                        var en = root.section(["battery", "energy_now_wh"], null)
                                        var ef = root.section(["battery", "energy_full_wh"], null)
                                        if (en !== null && ef !== null)
                                            return root.fixed(en, 1, "n/a") + " Wh / " + root.fixed(ef, 1, "n/a") + " Wh"
                                        var cn = root.section(["battery", "charge_now_mah"], null)
                                        var cf = root.section(["battery", "charge_full_mah"], null)
                                        if (cn !== null && cf !== null)
                                            return root.fixed(cn, 0, "n/a") + " mAh / " + root.fixed(cf, 0, "n/a") + " mAh"
                                        return "n/a"
                                    }
                                }
                                MetricLine {
                                    label: "Time"
                                    value: {
                                        var st = root.section(["battery", "status"], "")
                                        var tte = root.section(["battery", "time_to_empty_min"], null)
                                        var ttf = root.section(["battery", "time_to_full_min"], null)
                                        if (st === "Discharging" && tte !== null) {
                                            var h = Math.floor(tte / 60), m = tte % 60
                                            return (h > 0 ? h + " h " : "") + m + " min remaining"
                                        }
                                        if (st === "Charging" && ttf !== null) {
                                            var h2 = Math.floor(ttf / 60), m2 = ttf % 60
                                            return (h2 > 0 ? h2 + " h " : "") + m2 + " min to full"
                                        }
                                        if (st === "Full") return "Full"
                                        return "n/a"
                                    }
                                }
                                MetricLine {
                                    label: "Health"
                                    value: {
                                        var h = root.section(["battery", "health_percent"], null)
                                        return h === null ? "n/a" : root.fixed(h, 1, "n/a") + "%"
                                    }
                                }
                                MetricLine { label: "Technology"; value: root.section(["battery", "technology"], "n/a") || "n/a" }
                                MetricLine {
                                    label: "Cycles"
                                    value: {
                                        var c = root.section(["battery", "cycle_count"], null)
                                        return c === null ? "n/a" : String(c)
                                    }
                                }
                                MetricLine {
                                    label: "Model"
                                    value: {
                                        var mfr = root.section(["battery", "manufacturer"], "") || ""
                                        var mdl = root.section(["battery", "model_name"], "") || ""
                                        var full = (mfr + " " + mdl).trim()
                                        return full || "n/a"
                                    }
                                }
                            }
                        }
                    }

                    SensorCard {
                        Layout.fillWidth: true
                        Layout.columnSpan: parent.columns
                        Layout.preferredHeight: Kirigami.Units.gridUnit * 18
                        title: "Processes"
                        accent: root.coral
                        visible: Plasmoid.configuration.showProcesses
                        available: root.section(["processes", "available"], false)

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: Kirigami.Units.largeSpacing
                            anchors.topMargin: Kirigami.Units.gridUnit * 3
                            spacing: 3
                            Repeater {
                                model: root.section(["processes", "top"], [])
                                delegate: ProcessRow {
                                    Layout.fillWidth: true
                                    pid: modelData.pid
                                    name: modelData.name
                                    cpu: modelData.cpu_percent
                                    rss: root.bytes(modelData.rss_bytes, false)
                                    state: modelData.state || ""
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    component HeaderBlock: Rectangle {
        property string title
        property string subtitle
        color: "#0011161a"
        border.color: root.panelBorder
        border.width: 1
        radius: 6
        implicitHeight: Kirigami.Units.gridUnit * 4

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: 1
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: title
                color: root.textPrimary
                font.pixelSize: 20
                font.bold: true
                elide: Text.ElideRight
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: subtitle
                color: root.textSecondary
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
    }

    component SensorCard: Rectangle {
        id: card
        property string title
        property color accent
        property bool available: true
        default property alias content: body.data

        color: root.panelBg
        opacity: available ? 0.96 : 0.68
        border.color: available ? Qt.rgba(accent.r, accent.g, accent.b, 0.48) : root.panelBorder
        border.width: 1
        radius: 6

        Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 3
            color: card.accent
            opacity: card.available ? 0.95 : 0.35
        }

        PlasmaComponents3.Label {
            anchors.left: parent.left
            anchors.leftMargin: Kirigami.Units.largeSpacing
            anchors.top: parent.top
            anchors.topMargin: Kirigami.Units.smallSpacing
            text: card.title
            color: root.textPrimary
            font.pixelSize: 13
            font.bold: true
        }

        PlasmaComponents3.Label {
            anchors.right: parent.right
            anchors.rightMargin: Kirigami.Units.largeSpacing
            anchors.top: parent.top
            anchors.topMargin: Kirigami.Units.smallSpacing
            text: card.available ? "ONLINE" : "NO SENSOR"
            color: card.available ? card.accent : root.textSecondary
            font.pixelSize: 10
        }

        Item {
            id: body
            anchors.fill: parent
        }
    }

    component StatTile: Rectangle {
        property string label
        property string value
        property color accent
        property bool compact: false

        color: "#0b1013"
        border.color: Qt.rgba(accent.r, accent.g, accent.b, 0.42)
        border.width: 1
        radius: 4
        implicitHeight: compact ? Kirigami.Units.gridUnit * 3.1 : Kirigami.Units.gridUnit * 3.5

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 1
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: label
                color: root.textSecondary
                font.pixelSize: compact ? 9 : 10
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: value
                color: accent
                font.pixelSize: compact ? 10 : 13
                font.bold: true
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    component MarkerSummaryBar: Canvas {
        property string title
        property var values: []
        property var labels: []
        property var markerColors: []
        property color accent
        property real maxValue: 100

        onValuesChanged: requestPaint()
        onLabelsChanged: requestPaint()
        onMarkerColorsChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var left = 10;
            var right = width - 10;
            var trackY = Math.round(height * 0.48);
            var trackHeight = 7;

            ctx.fillStyle = "#0b1013";
            ctx.strokeStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.32);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.rect(0.5, 0.5, width - 1, height - 1);
            ctx.fill();
            ctx.stroke();

            ctx.fillStyle = root.textSecondary;
            ctx.font = "10px sans-serif";
            ctx.textAlign = "left";
            ctx.textBaseline = "top";
            ctx.fillText(title.toUpperCase(), left, 5);

            ctx.fillStyle = "#243238";
            ctx.fillRect(left, trackY, right - left, trackHeight);

            var fillValue = 0;
            for (var i = 0; i < values.length; i++) {
                fillValue = Math.max(fillValue, Number(values[i]) || 0);
            }
            var range = Number(maxValue) > 0 ? Number(maxValue) : Math.max(1, fillValue * 1.2);
            ctx.fillStyle = Qt.rgba(accent.r, accent.g, accent.b, 0.35);
            ctx.fillRect(left, trackY, (right - left) * Math.max(0, Math.min(range, fillValue)) / range, trackHeight);

            for (var j = 0; j < values.length; j++) {
                var value = Math.max(0, Math.min(range, Number(values[j]) || 0));
                var x = left + (right - left) * value / range;
                var color = markerColors[j] || accent;
                ctx.strokeStyle = color;
                ctx.lineWidth = 2;
                ctx.beginPath();
                ctx.moveTo(x, trackY - 5);
                ctx.lineTo(x, trackY + trackHeight + 5);
                ctx.stroke();

                ctx.fillStyle = color;
                ctx.font = "10px sans-serif";
                ctx.textBaseline = "bottom";
                if (j === 0) {
                    ctx.textAlign = "left";
                    ctx.fillText(labels[j] || "", left, height - 5);
                } else if (j === values.length - 1) {
                    ctx.textAlign = "right";
                    ctx.fillText(labels[j] || "", right, height - 5);
                } else {
                    ctx.textAlign = "center";
                    ctx.fillText(labels[j] || "", width / 2, height - 5);
                }
            }
        }
    }

    component MetricLine: RowLayout {
        property string label
        property string value
        spacing: Kirigami.Units.smallSpacing
        PlasmaComponents3.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
            text: label
            color: root.textSecondary
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: value
            color: root.textPrimary
            font.pixelSize: 11
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    component CompactMonitor: Rectangle {
        property real cpuValue
        property real memValue
        property string status
        implicitWidth: Kirigami.Units.gridUnit * 9
        implicitHeight: Kirigami.Units.gridUnit * 3
        color: "#cc11161a"
        border.color: root.panelBorder
        radius: 6

        RowLayout {
            anchors.fill: parent
            anchors.margins: 6
            spacing: 6
            DonutChart {
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2
                Layout.preferredHeight: Kirigami.Units.gridUnit * 2.2
                value: cpuValue
                accent: root.cyan
                label: "C"
                small: true
            }
            DonutChart {
                Layout.preferredWidth: Kirigami.Units.gridUnit * 2.2
                Layout.preferredHeight: Kirigami.Units.gridUnit * 2.2
                value: memValue
                accent: root.green
                label: "M"
                small: true
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: Math.round(cpuValue) + "% / " + Math.round(memValue) + "%"
                color: root.textPrimary
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
    }

    component DonutChart: Canvas {
        property real value
        property color accent
        property string label
        property bool small: false

        onValueChanged: requestPaint()
        onAccentChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var size = Math.min(width, height);
            var centerX = width / 2;
            var centerY = height / 2;
            var radius = size * 0.38;
            var lineWidth = Math.max(4, size * 0.12);
            ctx.lineCap = "round";
            ctx.lineWidth = lineWidth;
            ctx.strokeStyle = "#28343a";
            ctx.beginPath();
            ctx.arc(centerX, centerY, radius, 0, Math.PI * 2);
            ctx.stroke();
            ctx.strokeStyle = accent;
            ctx.beginPath();
            ctx.arc(centerX, centerY, radius, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.max(0, Math.min(100, value)) / 100);
            ctx.stroke();
            ctx.fillStyle = root.textPrimary;
            ctx.font = (small ? "10px" : "18px") + " sans-serif";
            ctx.textAlign = "center";
            ctx.textBaseline = "middle";
            ctx.fillText(label, centerX, centerY);
        }
    }

    component LineChart: Canvas {
        property var seriesA: []
        property var seriesB: []
        property color accentA
        property color accentB
        property real maxValue: 0
        property string labelA: ""
        property string labelB: ""
        property bool percentMode: false

        onSeriesAChanged: requestPaint()
        onSeriesBChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        function drawSeries(ctx, values, accent, scaleMax) {
            if (!values || values.length < 2) {
                return;
            }
            ctx.strokeStyle = accent;
            ctx.lineWidth = 2;
            ctx.beginPath();
            var left = 46;
            var right = 6;
            var top = 18;
            var bottom = 20;
            for (var i = 0; i < values.length; i++) {
                var x = left + (width - left - right) * i / Math.max(1, values.length - 1);
                var y = height - bottom - ((Number(values[i]) || 0) / scaleMax) * (height - top - bottom);
                if (i === 0) {
                    ctx.moveTo(x, y);
                } else {
                    ctx.lineTo(x, y);
                }
            }
            ctx.stroke();
        }

        function axisText(value) {
            if (percentMode) {
                return Math.round(value) + "%";
            }
            return root.bytes(value, true);
        }

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            ctx.fillStyle = "#0b1013";
            ctx.fillRect(0, 0, width, height);
            var left = 46;
            var right = 6;
            var top = 18;
            var bottom = 20;
            ctx.strokeStyle = root.gridLine;
            ctx.lineWidth = 1;
            ctx.font = "9px sans-serif";
            ctx.fillStyle = root.textSecondary;
            ctx.textAlign = "right";
            ctx.textBaseline = "middle";
            for (var i = 0; i < 5; i++) {
                var y = top + (height - top - bottom) * i / 4;
                ctx.beginPath();
                ctx.moveTo(left, y);
                ctx.lineTo(width - right, y);
                ctx.stroke();
            }
            ctx.beginPath();
            ctx.moveTo(left, top);
            ctx.lineTo(left, height - bottom);
            ctx.lineTo(width - right, height - bottom);
            ctx.stroke();
            var values = (seriesA || []).concat(seriesB || []);
            var scaleMax = maxValue > 0 ? maxValue : 1;
            for (var j = 0; j < values.length; j++) {
                scaleMax = Math.max(scaleMax, Number(values[j]) || 0);
            }
            scaleMax = scaleMax * 1.15;
            ctx.fillText(axisText(scaleMax), left - 4, top);
            ctx.fillText(axisText(scaleMax / 2), left - 4, top + (height - top - bottom) / 2);
            ctx.fillText(axisText(0), left - 4, height - bottom);
            ctx.textAlign = "left";
            ctx.textBaseline = "alphabetic";
            if (labelA.length > 0) {
                ctx.fillStyle = accentA;
                ctx.fillText(labelA, left, 11);
            }
            if (labelB.length > 0) {
                ctx.fillStyle = accentB;
                ctx.fillText(labelB, left + 78, 11);
            }
            ctx.fillStyle = root.textSecondary;
            ctx.textAlign = "right";
            ctx.fillText("now", width - right, height - 5);
            drawSeries(ctx, seriesA, accentA, scaleMax);
            drawSeries(ctx, seriesB, accentB, scaleMax);
        }
    }

    component BarStrip: Canvas {
        property var values: []
        property color accent

        onValuesChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d");
            ctx.reset();
            var count = Math.max(1, values.length);
            var gap = 2;
            var barWidth = Math.max(2, (width - gap * (count - 1)) / count);
            for (var i = 0; i < count; i++) {
                var value = Math.max(0, Math.min(100, Number(values[i]) || 0));
                var h = Math.max(2, (height - 2) * value / 100);
                ctx.fillStyle = "#263239";
                ctx.fillRect(i * (barWidth + gap), 0, barWidth, height);
                ctx.fillStyle = accent;
                ctx.fillRect(i * (barWidth + gap), height - h, barWidth, h);
            }
        }
    }

    component NetworkPeriodTile: Rectangle {
        property string period: ""
        property string rxBytes: "—"
        property string txBytes: "—"

        color: "#0b1013"
        border.color: Qt.rgba(root.teal.r, root.teal.g, root.teal.b, 0.32)
        border.width: 1
        radius: 5
        implicitHeight: Kirigami.Units.gridUnit * 4.4

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 7
            spacing: 3

            PlasmaComponents3.Label {
                Layout.fillWidth: true
                text: period
                color: root.teal
                font.pixelSize: 9
                font.bold: true
                font.letterSpacing: 1
                horizontalAlignment: Text.AlignHCenter
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                PlasmaComponents3.Label {
                    text: "↓"
                    color: root.teal
                    font.pixelSize: 12
                    font.bold: true
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: rxBytes
                    color: root.textPrimary
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                PlasmaComponents3.Label {
                    text: "↑"
                    color: root.chartSec
                    font.pixelSize: 12
                    font.bold: true
                }
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    text: txBytes
                    color: root.textPrimary
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }
        }
    }

    component RamBreakdownBar: Canvas {
        property real usedBytes: 0
        property real cachedBytes: 0
        property real totalBytes: 1

        onUsedBytesChanged: requestPaint()
        onCachedBytesChanged: requestPaint()
        onTotalBytesChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var t = Math.max(1, Number(totalBytes))
            var u = Math.max(0, Math.min(t, Number(usedBytes)))
            var c = Math.max(0, Math.min(t - u, Number(cachedBytes)))
            var barH = 8
            var barY = Math.round((height - barH) * 0.4)
            var labelY = height - 3

            ctx.fillStyle = "#243238"
            ctx.fillRect(0, barY, width, barH)

            ctx.fillStyle = root.green
            ctx.globalAlpha = 0.85
            ctx.fillRect(0, barY, (u / t) * width, barH)

            ctx.fillStyle = root.chartSec
            ctx.globalAlpha = 0.55
            ctx.fillRect((u / t) * width, barY, (c / t) * width, barH)
            ctx.globalAlpha = 1.0

            ctx.font = "9px sans-serif"
            ctx.textBaseline = "bottom"
            ctx.fillStyle = root.green
            ctx.textAlign = "left"
            ctx.fillText("USED", 2, labelY)
            ctx.fillStyle = root.chartSec
            ctx.textAlign = "center"
            ctx.fillText("CACHE", width / 2, labelY)
            ctx.fillStyle = root.textSecondary
            ctx.textAlign = "right"
            ctx.fillText("FREE", width - 2, labelY)
        }
    }

    component ProcessRow: RowLayout {
        property int pid
        property string name
        property real cpu
        property string rss
        property string state
        spacing: Kirigami.Units.smallSpacing
        PlasmaComponents3.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 4
            text: pid
            color: root.textSecondary
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        PlasmaComponents3.Label {
            Layout.fillWidth: true
            text: name
            color: root.textPrimary
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        PlasmaComponents3.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
            text: root.fixed(cpu, 1, "0") + "% CPU"
            color: root.coral
            font.pixelSize: 11
            horizontalAlignment: Text.AlignRight
        }
        PlasmaComponents3.Label {
            Layout.preferredWidth: Kirigami.Units.gridUnit * 5
            text: rss
            color: root.textSecondary
            font.pixelSize: 11
            horizontalAlignment: Text.AlignRight
        }
    }
}
