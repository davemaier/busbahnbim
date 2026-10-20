.pragma library

// Client for the HAFAS "mgate" JSON API behind verkehrsauskunft.verbundlinie.at
// (Steirischer Verkehrsverbund / BusBahnBim). The auth values below are the
// public ones the website's own webapp sends; the API is undocumented.

var ENDPOINT = "https://verkehrsauskunft.verbundlinie.at/hamm/gate"

var ENVELOPE = {
  ver: "1.59",
  lang: "eng",
  auth: { type: "AID", aid: "wf7mcf9bv3nv8g5f" },
  client: { id: "VAO", type: "WEB", name: "webapp", l: "vs_webapp" },
  ext: "VAO.22",
  formatted: false
}

var ICONS = {
  tram: "\u{F052C}",
  bus: "\u{F00E7}",
  train: "\u{F052D}",
  walk: "\u{F0583}",
  other: "\u{F00E7}"
}

// POST one service request; cb(error, result).
function request(meth, req, cb) {
  var body = JSON.parse(JSON.stringify(ENVELOPE))
  body.svcReqL = [{ meth: meth, req: req }]

  var xhr = new XMLHttpRequest()
  xhr.onreadystatechange = function() {
    if (xhr.readyState !== XMLHttpRequest.DONE) return
    if (xhr.status !== 200) { cb(xhr.status ? "HTTP " + xhr.status : "No connection", null); return }
    try {
      var data = JSON.parse(xhr.responseText)
      var svc = data.svcResL && data.svcResL[0]
      if (data.err && data.err !== "OK") cb(data.errTxt || data.err, null)
      else if (!svc) cb("Empty response", null)
      else if (svc.err !== "OK") cb(svc.errTxt || svc.err, null)
      else cb(null, svc.res)
    } catch (e) {
      cb(String(e), null)
    }
  }
  xhr.open("POST", ENDPOINT)
  xhr.setRequestHeader("Content-Type", "application/json")
  xhr.send(JSON.stringify(body))
}

// A stop is { name, extId, lid }. The station board only needs the extId.
function stopLid(stop) {
  return stop.lid || ("A=1@L=" + stop.extId + "@")
}

function searchStops(query, stationsOnly, cb) {
  request("LocMatch", {
    input: { field: "S", loc: { type: stationsOnly ? "S" : "ALL", name: query + "?" }, maxLoc: 8 }
  }, function(err, res) {
    if (err) { cb(err, []); return }
    var locs = (res.match && res.match.locL) || []
    cb(null, locs.map(function(l) {
      return { name: l.name, extId: l.extId || "", lid: l.lid, type: l.type }
    }))
  })
}

function fetchDepartures(stop, count, cb) {
  request("StationBoard", { type: "DEP", stbLoc: { lid: stopLid(stop) }, maxJny: count }, function(err, res) {
    cb(err, err ? [] : parseDepartures(res))
  })
}

function fetchTrips(from, to, when, cb) {
  request("TripSearch", {
    depLocL: [{ lid: stopLid(from) }],
    arrLocL: [{ lid: stopLid(to) }],
    outDate: ymd(when),
    outTime: hms(when),
    numF: 5,
    getPasslist: false
  }, function(err, res) {
    cb(err, err ? [] : parseTrips(res))
  })
}

// ---- Parsing ---------------------------------------------------------------

// "Straßenbahn 1" -> { short: "1", kind: "tram" }
function lineInfo(prod) {
  var name = (prod && prod.name) || ""
  var short = (prod && (prod.nameS || prod.number)) || name.replace(/^\S+\s+/, "")
  var kind = "other"
  if (/straßenbahn|tram|bim/i.test(name)) kind = "tram"
  else if (/bus/i.test(name)) kind = "bus"
  else if (/zug|bahn|^(S|R|REX|CJX|RJX?|IC|EC|ICE|NJ|WB|D)\s*\d*/i.test(name)) kind = "train"
  return { name: name, short: short, kind: kind }
}

// HAFAS times are HHMMSS, or DDHHMMSS when the stop is days after `date`.
function toDate(yyyymmdd, time) {
  if (!time) return null
  var t = String(time)
  var days = t.length > 6 ? parseInt(t.slice(0, t.length - 6), 10) : 0
  t = t.slice(-6)
  var d = String(yyyymmdd)
  return new Date(+d.slice(0, 4), +d.slice(4, 6) - 1, +d.slice(6, 8) + days,
                  +t.slice(0, 2), +t.slice(2, 4), +t.slice(4, 6))
}

function delayMinutes(planned, live) {
  return planned && live ? Math.round((live - planned) / 60000) : 0
}

function parseDepartures(res) {
  var prods = (res.common && res.common.prodL) || []
  var list = (res.jnyL || []).map(function(j) {
    var stop = j.stbStop
    var line = lineInfo(prods[stop.dProdX !== undefined ? stop.dProdX : j.prodX])
    var planned = toDate(j.date, stop.dTimeS)
    var live = toDate(j.date, stop.dTimeR)
    return {
      line: line.short,
      kind: line.kind,
      direction: j.dirTxt || "",
      planned: planned,
      time: live || planned,
      realtime: !!live,
      delay: delayMinutes(planned, live),
      platform: (stop.dPltfR || stop.dPltfS || {}).txt || "",
      cancelled: !!(stop.dCncl || j.isCncl)
    }
  })
  return list.sort(function(a, b) { return a.time - b.time })
}

function parseTrips(res) {
  var common = res.common || {}
  var locs = common.locL || []
  var prods = common.prodL || []
  return (res.outConL || []).map(function(con) {
    var sections = (con.secL || []).map(function(s) {
      var planned = toDate(con.date, s.dep.dTimeS)
      var live = toDate(con.date, s.dep.dTimeR)
      var section = {
        type: s.type,
        from: (locs[s.dep.locX] || {}).name || "",
        to: (locs[s.arr.locX] || {}).name || "",
        dep: live || planned,
        arr: toDate(con.date, s.arr.aTimeR || s.arr.aTimeS),
        delay: delayMinutes(planned, live),
        platform: s.type === "JNY" ? (s.dep.dPltfR || s.dep.dPltfS || {}).txt || "" : "",
        line: "",
        kind: "walk",
        direction: ""
      }
      if (s.type === "JNY" && s.jny) {
        var line = lineInfo(prods[s.jny.prodX])
        section.line = line.short
        section.kind = line.kind
        section.direction = s.jny.dirTxt || ""
      }
      return section
    })
    var rides = sections.filter(function(s) { return s.type === "JNY" })
    var first = sections[0], last = sections[sections.length - 1]
    var dep = first ? first.dep : toDate(con.date, con.dep.dTimeR || con.dep.dTimeS)
    var arr = last ? last.arr : toDate(con.date, con.arr.aTimeR || con.arr.aTimeS)
    return {
      dep: dep,
      arr: arr,
      minutes: dep && arr ? Math.round((arr - dep) / 60000) : 0,
      changes: con.chg || 0,
      delay: rides.length ? rides[0].delay : 0,
      sections: sections,
      rides: rides
    }
  })
}

// ---- Helpers for the UI ----------------------------------------------------

function filterDepartures(list, linesCsv, direction) {
  var lines = String(linesCsv || "").split(",")
    .map(function(s) { return s.trim().toLowerCase() })
    .filter(function(s) { return s !== "" })
  var dir = String(direction || "").trim().toLowerCase()
  return list.filter(function(d) {
    if (lines.length && lines.indexOf(String(d.line).toLowerCase()) < 0) return false
    if (dir && d.direction.toLowerCase().indexOf(dir) < 0) return false
    return true
  })
}

function minutesUntil(date, nowMs) {
  return Math.floor((date.getTime() - nowMs) / 60000)
}

function countdown(date, nowMs) {
  var m = minutesUntil(date, nowMs)
  if (m <= 0) return "now"
  if (m < 60) return m + "′"
  return hhmm(date)
}

function pad(n) { return n < 10 ? "0" + n : "" + n }
function hhmm(date) { return date ? pad(date.getHours()) + ":" + pad(date.getMinutes()) : "" }
function ymd(date) { return "" + date.getFullYear() + pad(date.getMonth() + 1) + pad(date.getDate()) }
function hms(date) { return pad(date.getHours()) + pad(date.getMinutes()) + "00" }

function duration(minutes) {
  return minutes < 60 ? minutes + " min" : Math.floor(minutes / 60) + " h " + pad(minutes % 60)
}

// "" / "now" -> now; "7:45", "0745", "7.45" -> today at that time.
function parseTime(text) {
  var s = String(text || "").trim().toLowerCase()
  var now = new Date()
  if (s === "" || s === "jetzt" || s === "now") return now
  var m = s.match(/^(\d{1,2})[:.]?(\d{2})$/)
  if (!m || +m[1] > 23 || +m[2] > 59) return null
  return new Date(now.getFullYear(), now.getMonth(), now.getDate(), +m[1], +m[2])
}

function shorten(text, max) {
  return text.length > max ? text.slice(0, max - 1).trim() + "…" : text
}
