import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Agent Fleet: every herdr agent with the Claude/Codex account it runs on, its model, effort, context
// window and estimated usage, plus suggestions for where to save. A display only: `agent-fleet collect`
// (systemd timer, every minute) writes the snapshot this watches.
Panel {
  id: root
  moduleName: "netsensia.agent-fleet"
  ipcTarget: "netsensia.agent-fleet"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string snapshotPath: home + "/.local/state/agent-fleet/snapshot.json"
  readonly property string collector: home + "/.local/bin/agent-fleet"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var snapshot: null
  property double nowMs: Date.now()
  property string filterId: "all"
  property bool cursorActive: false

  readonly property var agents: snapshot ? (snapshot.agents || []) : []
  readonly property var usedAccounts: accountsInUse()
  readonly property var filters: filterList()
  readonly property int filterIndex: {
    for (var i = 0; i < filters.length; i++) if (filters[i].id === filterId) return i
    return 0
  }
  readonly property var shownAgents: {
    var id = filters.length ? filters[filterIndex].id : "all"
    return agents.filter(function(a) { return id === "all" || a.account === id })
  }
  readonly property real peakWeight: {
    var peak = 0
    for (var i = 0; i < shownAgents.length; i++) peak = Math.max(peak, shownAgents[i].share || 0)
    return peak
  }
  readonly property var topSuggestions: snapshot ? (snapshot.suggestions || []).slice(0, 7) : []
  readonly property bool alarming: {
    for (var i = 0; i < usedAccounts.length; i++) {
      var w = weeklyLimit(usedAccounts[i])
      if (usedAccounts[i].agentCount > 0 && w && w.percent >= 0.9) return true
    }
    for (var j = 0; j < topSuggestions.length; j++) if (topSuggestions[j].severity >= 3) return true
    return false
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function fmtTokens(n) {
    n = Number(n || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, "") + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M"
    if (n >= 1e3) return Math.round(n / 1e3) + "K"
    return String(Math.round(n))
  }

  function fmtMoney(v) {
    v = Number(v || 0)
    if (v >= 100) return "$" + Math.round(v)
    if (v >= 10) return "$" + v.toFixed(0)
    return "$" + v.toFixed(2)
  }

  function ago(iso) {
    var t = new Date(String(iso || "")).getTime()
    if (!isFinite(t)) return ""
    var m = Math.max(0, Math.floor((root.nowMs - t) / 60000))
    if (m < 1) return "just now"
    if (m < 60) return m + "m ago"
    var h = Math.floor(m / 60)
    if (h < 48) return h + "h ago"
    return Math.floor(h / 24) + "d ago"
  }

  function until(iso) {
    var t = new Date(String(iso || "")).getTime()
    if (!isFinite(t)) return ""
    var m = Math.max(0, Math.floor((t - root.nowMs) / 60000))
    var h = Math.floor(m / 60), d = Math.floor(h / 24)
    if (d > 0) return d + "d " + (h % 24) + "h"
    if (h > 0) return h + "h " + (m % 60) + "m"
    return m + "m"
  }

  function shortModel(a) {
    var m = String(a.modelNow || "").replace(" (1M context)", " 1M")
    return m === "" ? "no turns yet" : m + (a.modelPending ? "*" : "")
  }

  function accountName(id) {
    var accts = snapshot ? (snapshot.accounts || []) : []
    for (var i = 0; i < accts.length; i++) if (accts[i].id === id) return accts[i].name
    return id
  }

  function accountForbidden(id) {
    var accts = snapshot ? (snapshot.accounts || []) : []
    for (var i = 0; i < accts.length; i++) if (accts[i].id === id) return !!accts[i].forbidden
    return false
  }

  function accountsInUse() {
    var accts = snapshot ? (snapshot.accounts || []) : []
    var out = []
    for (var i = 0; i < accts.length; i++) {
      var n = 0
      for (var j = 0; j < agents.length; j++) if (agents[j].account === accts[i].id && agents[j].status !== "gone") n++
      // Accounts with no agents still show, so a resting account's limits stay visible.
      if (n > 0 || ((accts[i].limits || []).length > 0 && !accts[i].forbidden))
        out.push(Object.assign({ agentCount: n }, accts[i]))
    }
    return out
  }

  function filterList() {
    var out = [{ id: "all", name: "All" }]
    for (var i = 0; i < usedAccounts.length; i++)
      if (usedAccounts[i].agentCount > 0) out.push({ id: usedAccounts[i].id, name: usedAccounts[i].name })
    return out
  }

  function weeklyLimit(acct) {
    var lims = acct ? (acct.limits || []) : []
    for (var i = 0; i < lims.length; i++) {
      var t = (String(lims[i].title) + " " + String(lims[i].label)).toLowerCase()
      if (t.indexOf("week") >= 0 && t.indexOf("fable") < 0 && lims[i].percent !== null) return lims[i]
    }
    return null
  }

  function sessionLimit(acct) {
    var lims = acct ? (acct.limits || []) : []
    for (var i = 0; i < lims.length; i++) {
      var t = (String(lims[i].title) + " " + String(lims[i].label)).toLowerCase()
      if (t.indexOf("session") >= 0 || t.indexOf("5-hour") >= 0 || t.indexOf("5h") >= 0) return lims[i]
    }
    return null
  }

  function accountCaption(acct) {
    var parts = []
    var s = sessionLimit(acct)
    if (s && s.percent !== null) parts.push("Session " + Math.round(s.percent * 100) + "%")
    var w = weeklyLimit(acct)
    if (w && w.resetsAt) parts.push("resets in " + until(w.resetsAt))
    var p = acct.projection
    if (p && p.atReset !== undefined) parts.push("pace: " + Math.round(p.atReset * 100) + "% at reset")
    parts.push(acct.agentCount === 0 ? "no agents" : acct.agentCount + (acct.agentCount === 1 ? " agent" : " agents"))
    return parts.join(" · ")
  }

  function heroMeta() {
    if (!snapshot) return "Collecting…"
    var working = 0
    for (var i = 0; i < agents.length; i++) if (agents[i].status === "working") working++
    var t = snapshot.totals || {}
    return (snapshot.demo ? "DEMO DATA · " : "") + agents.length + " agents · " + working + " working · Claude ≈ " + fmtMoney(t.costWeek) + " this week"
  }

  function usageText(a) {
    if (a.costKnown) return fmtMoney(a.costWeek)
    var w = a.week || []
    return fmtTokens((w[0] || 0) + (w[1] || 0) + (w[2] || 0) + (w[3] || 0)) + " tok"
  }

  function agentTooltip(a) {
    var w = a.week || [], t = a.today || []
    var lines = []
    var inTok = (w[0] || 0) + (w[2] || 0) + (w[3] || 0)
    var hit = inTok > 0 ? Math.round(100 * (w[2] || 0) / inTok) : 0
    if (a.costKnown)
      lines.push("Today " + fmtMoney(a.costToday) + " · 7 days " + fmtMoney(a.costWeek) + " (" + Math.round(100 * (a.share || 0)) + "% of Claude)")
    else
      lines.push("Today " + fmtTokens((t[0]||0)+(t[1]||0)+(t[2]||0)+(t[3]||0)) + " · 7 days " + usageText(a) + " (" + Math.round(100 * (a.share || 0)) + "% of Codex)")
    lines.push((w[4] || 0) + " requests · cache hit " + hit + "% · median reply " + (a.medianOutput || 0) + " tokens")
    lines.push("Context " + fmtTokens(a.context) + " of " + fmtTokens(a.contextLimit) + (a.lastActive ? " · last turn " + ago(a.lastActive) : ""))
    if (a.policy) lines.push("Policy: " + a.policy + (a.isLoop ? " · on a timer loop" : ""))
    var sg = a.suggestions || []
    for (var i = 0; i < sg.length; i++) lines.push("→ " + sg[i].text)
    lines.push("Click to focus " + a.pane)
    return lines.join("\n")
  }

  function statusColor(a) {
    if (a.status === "gone" || accountForbidden(a.account)) return root.urgent
    if (a.status === "working") return Color.accent
    if (a.status === "blocked") return root.urgent
    return root.dim
  }

  function selectFilter(index) {
    if (filters.length === 0) return
    var i = ((index % filters.length) + filters.length) % filters.length
    filterId = filters[i].id
  }

  function refreshNow() {
    if (!collectProc.running) collectProc.running = true
  }

  function focusAgent(name) {
    focusProc.command = ["herdr", "agent", "focus", name]
    focusProc.running = true
    root.close()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (flick) flick.contentY = 0
    refreshNow()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  FileView {
    path: root.snapshotPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.snapshot = JSON.parse(String(text() || "")) } catch (e) { console.warn("fleet", "bad snapshot", e) }
    }
  }

  Process { id: collectProc; command: [root.collector, "collect"] }
  Process { id: focusProc }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: { root.nowMs = Date.now(); root.refreshNow() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.selectFilter(root.filterIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(1180))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) { root.cursorActive = true; root.selectFilter(root.filterIndex + dx) }
        if (dy !== 0)
          flick.contentY = root.clamp(flick.contentY + dy * Style.space(56), 0, Math.max(0, flick.contentHeight - flick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Fleet"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: button.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Accounts ----------
          PanelSeparator { foreground: root.foreground; visible: root.usedAccounts.length > 0 }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.usedAccounts.length > 0

            PanelSectionHeader { text: "ACCOUNTS"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: root.usedAccounts
              AccountRow { required property var modelData; width: parent.width; acct: modelData }
            }
          }

          // ---------- Agents ----------
          PanelSeparator { foreground: root.foreground }

          Column {
            id: agentSection
            width: parent.width
            spacing: Style.spacing.md

            Item {
              width: parent.width
              implicitHeight: agentsHeader.implicitHeight
              PanelSectionHeader { id: agentsHeader; text: "AGENTS"; foreground: root.foreground; fontFamily: root.fontFamily }
              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "est. last 7 days"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Row {
              id: filterRow
              visible: root.filters.length > 2
              width: parent.width
              spacing: Style.spacing.md
              readonly property real cellWidth: root.filters.length > 0 ? (width - spacing * (root.filters.length - 1)) / root.filters.length : 0
              Repeater {
                model: root.filters
                Button {
                  required property var modelData
                  required property int index
                  width: filterRow.cellWidth
                  text: modelData.name
                  selected: index === root.filterIndex
                  hasCursor: root.cursorActive && index === root.filterIndex
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: { root.cursorActive = true; root.selectFilter(index) }
                }
              }
            }

            Repeater {
              model: root.shownAgents
              AgentRow {
                required property var modelData
                width: agentSection.width
                agent: modelData
                share: root.peakWeight > 0 ? (modelData.share || 0) / root.peakWeight : 0
              }
            }

            Text {
              visible: root.snapshot && root.snapshot.other && root.filterId === "all"
              width: parent.width
              text: root.snapshot && root.snapshot.other
                ? "Claude work outside herdr agents (one-off sessions, pre-restart history): " + root.fmtMoney(root.snapshot.other.costWeek)
                : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Suggestions ----------
          PanelSeparator { foreground: root.foreground; visible: root.topSuggestions.length > 0 }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.topSuggestions.length > 0

            PanelSectionHeader { text: "WHERE TO SAVE"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              model: root.topSuggestions
              Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: modelData.agent + " — " + modelData.text
                  + (modelData.saving >= 1 ? "  (≈" + root.fmtMoney(modelData.saving) + "/wk)" : "")
                color: modelData.severity >= 2 ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Text {
            width: parent.width
            topPadding: Style.space(2)
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: "Claude $ = API list-price estimate, for comparing agents · * = switched, no reply yet"
              + (root.snapshot ? " · updated " + root.ago(root.snapshot.updatedAt) : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
    implicitHeight: thickness
    Rectangle { id: meterTrack; anchors.fill: parent; radius: height / 2; color: root.track }
    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground
    }
  }

  component AccountRow: Column {
    id: accountRow
    property var acct: null
    readonly property var weekly: root.weeklyLimit(acct)
    readonly property bool alarming: !!weekly && weekly.percent >= 0.9
    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(acctName.implicitHeight, acctValue.implicitHeight)
      Text {
        id: acctName
        textFormat: Text.PlainText
        text: accountRow.acct ? accountRow.acct.name + (accountRow.acct.plan ? "  ·  " + accountRow.acct.plan : "") : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        id: acctValue
        textFormat: Text.PlainText
        text: accountRow.weekly ? "Weekly " + Math.round(accountRow.weekly.percent * 100) + "%" : "—"
        color: accountRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    Meter { width: parent.width; value: accountRow.weekly ? accountRow.weekly.percent : -1; alarming: accountRow.alarming }
    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: accountRow.acct ? root.accountCaption(accountRow.acct) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  component AgentRow: Item {
    id: row
    property var agent: null
    property real share: 0
    readonly property real ctxRatio: agent && agent.contextLimit > 0 ? agent.context / agent.contextLimit : 0
    implicitHeight: rowCol.implicitHeight + Style.spacing.md * 2

    Rectangle { anchors.fill: parent; radius: Style.cornerRadius; color: root.alpha(root.foreground, rowHover.containsMouse ? 0.09 : 0.04) }
    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(row.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.10)
    }

    Column {
      id: rowCol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(3)

      Item {
        width: parent.width
        implicitHeight: agentName.implicitHeight
        Rectangle {
          id: dot
          width: Style.space(7); height: width; radius: width / 2
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          color: row.agent ? root.statusColor(row.agent) : root.dim
        }
        Text {
          id: agentName
          textFormat: Text.PlainText
          text: row.agent ? row.agent.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
          anchors.left: dot.right
          anchors.leftMargin: Style.space(8)
          anchors.right: usage.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          id: usage
          textFormat: Text.PlainText
          text: row.agent ? root.usageText(row.agent) + "  " + Math.round(100 * (row.agent.share || 0)) + "%" : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Item {
        width: parent.width
        implicitHeight: detail.implicitHeight
        Text {
          id: detail
          textFormat: Text.PlainText
          text: row.agent
            ? root.shortModel(row.agent) + (row.agent.effort ? " · " + row.agent.effort : "") + " · " + root.accountName(row.agent.account)
              + ((row.agent.suggestions || []).length ? "  ⚑" : "")
            : ""
          color: row.agent && root.accountForbidden(row.agent.account) ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.leftMargin: Style.space(15)
          anchors.right: ctxMeter.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
        }
        Meter {
          id: ctxMeter
          width: Style.space(70)
          anchors.right: ctxText.left
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          value: row.ctxRatio
          alarming: row.ctxRatio >= 0.8
        }
        Text {
          id: ctxText
          textFormat: Text.PlainText
          text: row.agent ? root.fmtTokens(row.agent.context) + "/" + root.fmtTokens(row.agent.contextLimit) : ""
          color: row.ctxRatio >= 0.8 ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignRight
          width: Style.space(78)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    MouseArea {
      id: rowHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (row.agent) root.focusAgent(row.agent.name)
    }

    PanelToolTip {
      visible: rowHover.containsMouse
      text: row.agent ? root.agentTooltip(row.agent) : ""
      fontFamily: root.fontFamily
    }
  }
}
