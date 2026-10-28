"""Builds the Dynatrace pipeline diagrams (SVG) and renders them to PNG with headless Chrome or Edge.

Usage: python build_diagrams.py            SVG + PNG next to this file
       python build_diagrams.py --svg-only
"""
import os
import shutil
import subprocess
import sys
from xml.sax.saxutils import escape

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1600, 900
SANS = "Segoe UI, Helvetica, Arial, sans-serif"
MONO = "Consolas, Menlo, monospace"
INK, MUTED, LINE, BG = "#1F2933", "#52606D", "#9AA5B1", "#FFFFFF"
STAGE = {  # stroke, fill
    "source": ("#52606D", "#F2F4F6"),
    "pipeline": ("#1F6FB2", "#EEF4FB"),
    "metrics": ("#2E7D4F", "#EDF7F1"),
    "storage": ("#A86B12", "#FBF4E8"),
    "consumer": ("#5B3FA8", "#F3F0FA"),
    "note": ("#9AA5B1", "#F7F8FA"),
}


class Svg:
    def __init__(self, title, subtitle):
        self.parts = []
        self.text(60, 66, title, 34, 700)
        for i, line in enumerate(subtitle if isinstance(subtitle, list) else [subtitle]):
            self.text(60, 100 + i * 24, line, 18, fill=MUTED)

    def rect(self, x, y, w, h, stage="note", rx=10, dash=False, sw=2):
        stroke, fill = STAGE[stage]
        extra = ' stroke-dasharray="7 5"' if dash else ""
        self.parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" '
                          f'stroke="{stroke}" stroke-width="{sw}"{extra}/>')

    def text(self, x, y, s, size=16, weight=400, fill=INK, anchor="start", mono=False):
        family = MONO if mono else SANS
        self.parts.append(f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
                          f'fill="{fill}" text-anchor="{anchor}">{escape(s)}</text>')

    def lines(self, x, y, items, size=15, lh=22, anchor="start"):
        """items: str (sans), ("mono", str), ("bold", str), ("muted", str) or "" for a gap"""
        for item in items:
            kind, s = item if isinstance(item, tuple) else ("sans", item)
            if s:
                self.text(x, y, s, size if kind != "mono" else size - 1, 700 if kind == "bold" else 400,
                          MUTED if kind == "muted" else INK, anchor, mono=kind == "mono")
            y += lh
        return y

    def arrow(self, points, color=LINE, label=None):
        d = "M " + " L ".join(f"{x} {y}" for x, y in points)
        self.parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="2.5" marker-end="url(#arrow)"/>')
        if label:
            (x1, y1), (x2, y2) = points[0], points[1]
            self.text((x1 + x2) / 2, min(y1, y2) - 10, label, 13, fill=MUTED, anchor="middle")

    def dot(self, cx, cy, color, r=9):
        self.parts.append(f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{color}"/>')

    def raw(self, s):
        self.parts.append(s)

    def save(self, name):
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">\n'
               f'<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
               f'orient="auto-start-reverse"><path d="M 0 0 L 10 5 L 0 10 z" fill="{LINE}"/></marker></defs>\n'
               f'<rect width="{W}" height="{H}" fill="{BG}"/>\n' + "\n".join(self.parts) + "\n</svg>\n")
        path = os.path.join(HERE, name + ".svg")
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(svg)
        return path


def overview():
    s = Svg("Nexus log pipeline in Dynatrace",
            "From the ECS containers to the dashboard, the alerts and the daily report")

    s.rect(40, 150, 280, 490, "source")
    s.text(60, 186, "1. Sources", 20, 700)
    s.rect(60, 210, 240, 128, "source", sw=1.5)
    s.lines(76, 238, [("bold", "Adapters"), "call the backends", ("mono", "/aws/ecs/srv/"), ("mono", "<cluster>ws-*-adapter")])
    s.rect(60, 352, 240, 128, "source", sw=1.5)
    s.lines(76, 380, [("bold", "mngr (proxy WS / ESB)"), "answers the channel (SOAP)", ("mono", "/aws/ecs/srv/"),
                      ("mono", "<cluster>ws-*-mngr")])
    s.lines(60, 518, [("bold", "CloudWatch Logs"), "one log group per container,", "forwarded to Dynatrace with",
                      ("mono", "aws.log_group")])

    s.arrow([(320, 400), (348, 400)])

    s.rect(350, 150, 820, 490, "pipeline")
    s.text(370, 186, "2. OpenPipeline, pipeline nexus", 20, 700)
    s.rect(370, 300, 170, 200, "pipeline", sw=1.5)
    s.lines(386, 330, [("bold", "Route"), "dynamic route:", "log group under", ("mono", "/aws/ecs/srv/"),
                       "ending in", ("mono", "-adapter | -mngr")])
    s.arrow([(540, 400), (568, 400)])
    s.rect(570, 220, 230, 360, "pipeline", sw=1.5)
    s.lines(586, 250, [("bold", "Processing"), "13 DQL processors,", "one per line type", "", "turn the raw line into",
                       ("mono", "nexus.* attributes:"), "kind, cluster, service,", "channel, rquid, outcome,",
                       "http_code, duration_ms", "", ("muted", "planned: drop OneAgent"), ("muted", "noise, mask customer id")])
    s.arrow([(800, 330), (828, 330)])
    s.arrow([(800, 480), (828, 480)])
    s.rect(830, 240, 320, 160, "metrics", sw=1.5)
    s.lines(846, 270, [("bold", "Metric extraction"), "12 metrics, key prefix", ("mono", "custom.nexus.log.*"),
                       "counts and times by cluster,", "service, channel, outcome"])
    s.rect(830, 420, 320, 160, "storage", sw=1.5)
    s.lines(846, 450, [("bold", "Storage"), ("mono", "bck-nexus-error-log"), "error lines only (small)",
                       ("mono", "logs_integracion"), "everything else (large)"])

    s.arrow([(1170, 400), (1198, 400)])

    s.rect(1200, 150, 360, 490, "consumer")
    s.text(1220, 186, "3. Who reads it", 20, 700)
    cards = [
        ("Nexus V2 dashboard", ["status at a glance, KPIs, alerts,", "error detail, trace by rquid"]),
        ("Custom alerts", ["Anomaly Detection over the", "metrics, one series per cluster"]),
        ("Notebooks 1 to 4", ["context, pipeline, dashboard, alerts;", "a test next to every piece"]),
        ("daily_report.sh", ["report for the team chat:", "metrics + error bucket"]),
    ]
    for i, (name, desc) in enumerate(cards):
        y = 206 + i * 106
        s.rect(1220, y, 320, 94, "consumer", sw=1.5)
        s.lines(1236, y + 28, [("bold", name)] + desc)

    s.rect(40, 670, 1520, 190, "note")
    s.text(60, 704, "Why it is built this way", 20, 700)
    cols = [
        ("30M transactions a day", ["A query over raw logs scans everything", "in its time range. Over a full day that",
                                    "does not scale."]),
        ("Metrics are computed at ingest", ["A tile or an alert over a metric costs the", "same with any traffic and any time range."]),
        ("Errors get their own bucket", ["Error detail reads a small bucket. The large", "one is read only to follow one rquid or a",
                                         "short window."]),
    ]
    for i, (head, body) in enumerate(cols):
        s.lines(60 + i * 505, 742, [("bold", head)] + body, size=16, lh=24)
    return s.save("01-pipeline-overview")


def processing():
    s = Svg("Processing: one DQL processor per line type",
            ["Each processor has a matching condition and a script that adds nexus.* attributes. They run in order,",
             "so a later processor can overwrite nexus.kind."])
    cols = [(60, "#"), (100, "Source"), (200, "Line type"), (510, "Matches lines with"), (900, "Adds (without the nexus. prefix)")]
    for x, head in cols:
        s.text(x, 164, head, 15, 700, MUTED)
    rows = [
        ("0", "both", "Log level", ("sans", "every routed line"), ["loglevel (ERROR, WARN, INFO...)"]),
        ("1", "both", "Common context", ("sans", "every routed line"), ["cluster, layer (adapter | mngr), component"]),
        ("2", "adapter", "Request headers", ("mono", "::HEAD::["), ["rquid, channel (X-Name), service (X-Referer)"]),
        ("3", "adapter", "Adapter response", ("mono", "::AUDIT::RESP::"),
         ["kind = audit_resp, http_code,", "outcome = ok_2xx | business_412 | error | unknown"]),
        ("4", "adapter", "Exceptions", ("mono", "GenericExceptionMapper + HttpCode::"),
         ["kind = timeout_504 | mapping_error | technical_error,", "http_code, mapping.direction, mapping.rule, mapping.field"]),
        ("5", "adapter", "Backend time", ("mono", "RSIN"),
         ["kind = backend_time, duration_ms,", "latency_bucket (0-100ms, 100-500ms, 500ms-1s, 1-5s, 5s+)"]),
        ("6", "mngr", "ESB trace and steps", ("mono", "[/"),
         ["kind = esb_step | mngr_trace, esb.step, duration_ms,", "rquid, channel, service"]),
        ("7", "mngr", "mngr errors", ("mono", "[ERROR"), ["kind = mngr_error"]),
        ("8", "mngr", "SOAP answer to the channel", ("mono", "<caracterAceptacion>"),
         ["kind = soap_resp, acceptance (B | M | C),", "soap.operation, soap.msg_code"]),
        ("9", "mngr", "Consumer mismatch (WARN)", ("mono", "Consumidor no coincide con..."), ["kind = consumer_mismatch"]),
        ("10", "adapter", "Stratus reply after timeout", ("mono", "despues de timeout"), ["kind = stratus_late_reply"]),
        ("11", "adapter", "Incomplete backend data", ("mono", "[STREAM]"),
         ["kind = stream_incomplete_list | stream_null_chars |", "stream_other, stream.attribute"]),
        ("12", "adapter", "Shutdown noise", ("mono", "[Error Occurred After Shutdown]"),
         ["kind = shutdown_noise (kept, left out of the counts)"]),
    ]
    tag = {"both": "source", "adapter": "pipeline", "mngr": "consumer"}
    y0, rh = 178, 49
    for i, (n, src, name, match, adds) in enumerate(rows):
        y = y0 + i * rh
        if i % 2 == 0:
            s.raw(f'<rect x="40" y="{y}" width="1520" height="{rh}" fill="#F7F8FA"/>')
        mid = y + rh / 2
        s.text(60, mid + 6, n, 16, 700)
        stroke, fill = STAGE[tag[src]]
        s.raw(f'<rect x="100" y="{mid - 13}" width="80" height="26" rx="13" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        s.text(140, mid + 5, src, 13, 600, stroke, "middle")
        s.text(200, mid + 6, name, 16)
        s.text(510, mid + 6, match[1], 15 if match[0] == "mono" else 16, fill=INK if match[0] == "mono" else MUTED,
               mono=match[0] == "mono")
        if len(adds) == 1:
            s.text(900, mid + 5, adds[0], 14, mono=True)
        else:
            s.text(900, mid - 4, adds[0], 14, mono=True)
            s.text(900, mid + 15, adds[1], 14, mono=True)
    s.lines(60, y0 + len(rows) * rh + 30, [
        ("muted", "Conditions use matchesValue: case-insensitive, with * as a wildcard. The literal texts are the ones the "
                  "services write in their logs."),
        ("muted", "Planned at the end of the stage: drop the OneAgent info lines ([native], [cstats]) and mask "
                  "X-CustIdentNum in the adapter headers."),
    ], size=15, lh=24)
    return s.save("02-processing")


def metrics():
    s = Svg("Metric extraction: 12 metrics computed at ingest",
            ["Keys start with custom.nexus.log. Dimensions drop the nexus. prefix: metric queries group by cluster, "
             "service...;", "log queries by nexus.cluster, nexus.service..."])
    cards = [
        ("adapter", "adapter.responses", "counter", "audit_resp", "cluster, service, channel, outcome, http_code",
         "KPIs, % error, status, daily report"),
        ("adapter", "adapter.timeouts", "counter", "timeout_504", "cluster, service, channel", "504 timeouts and their alert"),
        ("adapter", "adapter.mapping_errors", "counter", "mapping_error",
         "cluster, service, channel, mapping.direction, mapping.field", "mapping errors and their alert"),
        ("adapter", "adapter.backend_calls", "counter", "backend_time", "cluster, component, latency_bucket",
         "% of slow backend calls, alert"),
        ("adapter", "adapter.backend_ms", "value: duration_ms", "backend_time", "cluster, component",
         "backend latency: average, maximum"),
        ("adapter", "adapter.stratus_late_replies", "counter", "stratus_late_reply", "cluster, component",
         "Stratus replies after the timeout"),
        ("adapter", "adapter.stream_issues", "counter", "stream_*", "cluster, component, kind, stream.attribute",
         "data quality of the backend"),
        ("mngr", "mngr.errors", "counter", "mngr_error", "cluster, service, channel", "mngr errors and their alert"),
        ("mngr", "mngr.soap_responses", "counter", "soap_resp", "cluster, acceptance, soap.operation, soap.msg_code",
         "% of M answers to the channel"),
        ("mngr", "mngr.consumer_mismatch", "counter", "consumer_mismatch", "cluster", "mismatches per 100 transactions"),
        ("mngr", "esb.step_ms", "value: duration_ms", "esb_step", "cluster, service, esb.step", "slowest ESB steps"),
        ("both", "log_lines", "counter", "any kind but shutdown_noise", "cluster, component, loglevel",
         "log volume by level, pipeline health"),
    ]
    tag = {"both": "source", "adapter": "pipeline", "mngr": "consumer"}
    cw, ch, gap = 355, 200, 20
    for i, (src, name, typ, kind, dims, used) in enumerate(cards):
        x, y = 60 + (i % 4) * (cw + gap), 160 + (i // 4) * (ch + gap)
        s.rect(x, y, cw, ch, "metrics", sw=1.5)
        stroke, fill = STAGE[tag[src]]
        s.raw(f'<rect x="{x + cw - 96}" y="{y + 14}" width="80" height="24" rx="12" fill="{fill}" stroke="{stroke}" stroke-width="1.5"/>')
        s.text(x + cw - 56, y + 31, src, 13, 600, stroke, "middle")
        s.text(x + 16, y + 32, name, 16 if len(name) <= 24 else 14, 700, mono=True)
        s.text(x + 16, y + 58, typ, 14, fill=MUTED)
        s.text(x + 16, y + 82, "from kind = " + kind, 14, mono=True)
        s.text(x + 16, y + 110, "Dimensions", 13, 700, MUTED)
        dim_lines, cur = [], ""
        for part in dims.split(", "):
            nxt = (cur + ", " + part) if cur else part
            if len(nxt) > 40:
                dim_lines.append(cur + ",")
                cur = part
            else:
                cur = nxt
        dim_lines.append(cur)
        for j, line in enumerate(dim_lines):
            s.text(x + 16, y + 130 + j * 19, line, 13, mono=True)
        s.text(x + 16, y + ch - 16, used, 14)
    s.lines(60, 850, [("muted", "A counter adds 1 per matching line. A value metric stores duration_ms, so a query can take "
                                "its sum, average or maximum.")], size=15)
    return s.save("03-metrics")


def storage_and_consumers():
    s = Svg("Storage and who reads what",
            "Every processed line lands in one of two buckets; dashboards, alerts and reports pick the cheapest source")
    st, _ = STAGE["storage"]

    s.rect(190, 160, 240, 60, "pipeline", sw=1.5)
    s.text(310, 197, "Processed line", 17, 700, anchor="middle")
    s.arrow([(310, 220), (310, 252)])
    s.raw(f'<polygon points="310,255 440,320 310,385 180,320" fill="#FFFFFF" stroke="{st}" stroke-width="2"/>')
    s.lines(310, 314, [("bold", "Is it an"), ("bold", "error line?")], size=16, lh=22, anchor="middle")
    s.arrow([(180, 320), (120, 320), (120, 428)])
    s.text(150, 310, "yes", 15, 700, MUTED, "middle")
    s.arrow([(440, 320), (575, 320), (575, 428)])
    s.text(475, 312, "no", 15, 700, MUTED, "middle")

    s.rect(40, 430, 330, 280, "storage")
    s.lines(58, 462, [("mono", "bck-nexus-error-log"), "", "kind is one of", ("mono", "mapping_error, timeout_504,"),
                      ("mono", "technical_error, mngr_error,"), ("mono", "stratus_late_reply, stream_*"),
                      "or outcome = error", "", ("bold", "Small: cheap over long ranges"), "long retention (e.g. 90 days)"],
            size=16, lh=23)
    s.rect(410, 430, 330, 280, "storage")
    s.lines(428, 462, [("mono", "logs_integracion"), "", "everything else:", "healthy traffic, ESB steps,",
                       "backend times, SOAP answers", "(B / M / C)", "", "", ("bold", "Large: short ranges only"),
                       "trace by rquid, diagnosis"], size=16, lh=23)

    s.rect(40, 740, 700, 120, "note")
    s.lines(58, 772, [("bold", "One failed call, two lines"),
                      "The error bucket keeps the error response (audit_resp) and its cause",
                      "(timeout_504, mapping_error...). Count transactions by rquid, not lines."], size=16, lh=24)

    s.text(800, 196, "Who reads what", 22, 700)
    heads = [(1262, "Metrics", "metrics"), (1372, "Error bucket", "storage"), (1490, "logs_integracion", "storage")]
    for x, head, stage in heads:
        s.text(x, 236, head, 14, 700, MUTED, "middle", mono=head == "logs_integracion")
    rows = [
        ("Nexus V2: status and sections 1 to 4", "KPIs, adapters, proxy, alerts, volume", (1, 0, 0)),
        ("Nexus V2: 5. error detail", "messages, mapping examples, rquids", (0, 1, 0)),
        ("Nexus V2: 6. transactions, trace by rquid", "one transaction across both buckets", (0, 1, 1)),
        ("Nexus V2: 7. pipeline health", "last 15 minutes only", (0, 1, 1)),
        ("Custom alerts (Anomaly Detection)", "evaluated every minute, per cluster", (1, 0, 0)),
        ("daily_report.sh", "counts from metrics, detail from errors", (1, 1, 0)),
        ("Notebooks", "a test next to each processor and metric", (1, 1, 1)),
    ]
    y0, rh = 252, 62
    for i, (name, sub, marks) in enumerate(rows):
        y = y0 + i * rh
        if i % 2 == 0:
            s.raw(f'<rect x="790" y="{y}" width="770" height="{rh}" fill="#F7F8FA"/>')
        s.text(806, y + 27, name, 16, 700)
        s.text(806, y + 49, sub, 14, fill=MUTED)
        for (x, _, stage), on in zip(heads, marks):
            if on:
                s.dot(x, y + rh / 2, STAGE[stage][0])
            else:
                s.raw(f'<circle cx="{x}" cy="{y + rh / 2}" r="5" fill="none" stroke="{LINE}" stroke-width="1.5"/>')
    s.lines(806, y0 + len(rows) * rh + 36, [
        ("muted", "Counts and trends come from metrics; messages and examples from the"),
        ("muted", "error bucket; the large bucket only for one rquid or a short window."),
    ], size=16, lh=24)
    return s.save("04-storage-and-consumers")


def find_browser():
    for path in (r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                 r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"):
        if os.path.exists(path):
            return path
    return shutil.which("chromium") or shutil.which("google-chrome") or shutil.which("chrome")


def to_png(svg_path):
    browser = find_browser()
    if not browser:
        print("no Chrome or Edge found, PNG skipped")
        return
    png = svg_path[:-4] + ".png"
    subprocess.run([browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=2",
                    f"--window-size={W},{H}", f"--screenshot={png}", "file:///" + svg_path.replace("\\", "/")],
                   check=True, capture_output=True)
    print("wrote", os.path.basename(png))


if __name__ == "__main__":
    for build in (overview, processing, metrics, storage_and_consumers):
        path = build()
        print("wrote", os.path.basename(path))
        if "--svg-only" not in sys.argv:
            to_png(path)
