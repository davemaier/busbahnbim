import QtQuick
import Quickshell.Io

// One HAFAS API call, made with curl. Every request is its own process, so it
// gets a fresh connection and a hard time limit (Qt's XMLHttpRequest could hang
// forever after sleep or a network change). Destroys itself when done.
Process {
  id: root

  property string url: ""
  property string body: ""
  property var callback: null   // callback(error, responseText)

  property bool exited: false
  property int exitCode: 0
  property bool streamDone: false
  property string output: ""

  command: ["curl", "-fsS", "--connect-timeout", "5", "--max-time", "8",
            "-H", "Content-Type: application/json", "--data-binary", body, url]
  running: true

  stdout: StdioCollector {
    onStreamFinished: {
      root.output = text
      root.streamDone = true
      root.finish()
    }
  }

  onExited: function(code) {
    root.exitCode = code
    root.exited = true
    root.finish()
  }

  // Wait for both the exit code and the full output.
  function finish() {
    if (!exited || !streamDone || !callback) return
    var cb = callback
    callback = null
    if (exitCode === 0) cb(null, output)
    else if (exitCode === 28) cb("Request timed out", null)
    else if (exitCode === 6 || exitCode === 7) cb("No connection", null)
    else cb("Request failed (curl " + exitCode + ")", null)
    root.destroy()
  }
}
