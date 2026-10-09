#!/usr/bin/env python3
"""Local Linux/ARM64 adapter for the unmodified upstream validated load generator.

Run in the supplied toolchain container. Databases live on the VM's native disk,
not the macOS bind mount. Contract SQL mirrors verification/bench/contracts.rb;
only the five requested routes are selected (no avatar/static/health benchmarks).
"""
import argparse
import contextlib
import gzip
import hashlib
import html
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import signal
import sqlite3
import statistics
import subprocess
import tempfile
import time
import urllib.parse

WORKSPACE = Path(os.environ.get("CAMPFIRE_WORKSPACE", "/workspace"))
MOJO = Path(__file__).resolve().parents[1]
VERIFICATION = WORKSPACE / "once-campfire-verification"
SEED = VERIFICATION / "fixtures/default"
LOADGEN = VERIFICATION / "loadgen/target/release/loadgen"
ROUTES = ["room_show", "messages_page", "sidebar", "search", "post_message"]
NAMES = ["Room page", "Messages page", "Sidebar", "Search", "Post a message"]
PORT = 25130
BASE = f"http://127.0.0.1:{PORT}"


@contextlib.contextmanager
def connection(path):
    with contextlib.closing(sqlite3.connect(path)) as conn:
        with conn:
            yield conn


def command(args, **kwargs):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True, **kwargs)
    if result.returncode:
        # Do not echo arguments: login arguments contain disposable passwords.
        raise RuntimeError(f"{args[0]} exited {result.returncode}: {result.stderr[-6000:]}")
    return result.stdout


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def request(path, cookie="", method="GET", body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=30)
    h = {"Cookie": cookie, "Accept-Encoding": "gzip"}
    h.update(headers or {})
    try:
        connection.request(method, path, body=body, headers=h)
        response = connection.getresponse()
        wire = response.read()
        data = gzip.decompress(wire) if response.getheader("Content-Encoding") == "gzip" else wire
        return response.status, dict(response.getheaders()), data, len(wire)
    finally:
        connection.close()


def loadgen(*args, client_cpus="4-7"):
    return json.loads(command(["taskset", "-c", client_cpus, LOADGEN, *args]))


def check_sample(value):
    assert value["errors"] == 0, value
    assert value["invalid_responses"] == 0, value
    assert value["validation"] == "route-contract-v1", value
    assert value["ok"] > 0, value
    assert value["statuses"] == {"200": value["ok"]}, value


def fixture_env():
    return dict(line.split("=", 1) for line in (SEED / "reference.env").read_text().splitlines()
                if line and not line.startswith("#"))


def validate_server_log(path):
    """Fail closed on dropped background work or runtime crashes, including shutdown."""
    patterns = {
        "dropped background work": r"dropping (?:job|notification)|dropped [1-9][0-9]* notifications|discarded [1-9][0-9]* queued jobs|queue full|queue is full|durable (?:worker|claim|job).*failed|job failed|handler failed|were abandoned",
        "runtime/worker failure": r"KGEN_CompilerRT_DestroyGlobals|Worker (?:exited unexpectedly|failed:)|Background job failed:|Request failed:|panicked at|Segmentation fault",
    }
    failures = []
    for line in path.read_text(errors="replace").splitlines():
        for label, pattern in patterns.items():
            if re.search(pattern, line, re.I):
                failures.append(label)
    if failures:
        counts = {kind: failures.count(kind) for kind in sorted(set(failures))}
        raise RuntimeError(f"Server log gate failed: {counts}; inspect {path}")


@contextlib.contextmanager
def server(app, destination, server_cpus="0-3", cache=True, verify_log=False):
    """Each run receives an independent pristine seed and disposable process group."""
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f"campfire-{app}-") as tmp:
        runtime = Path(tmp)
        shutil.copytree(SEED / "db", runtime / "db")
        shutil.copytree(SEED / "storage", runtime / "files")
        db = runtime / "db/production.sqlite3"
        with connection(db) as conn:
            conn.execute("UPDATE push_subscriptions SET endpoint='https://127.0.0.1:9/push/'||id")
            conn.execute("UPDATE webhooks SET url='http://127.0.0.1:9/hook/'||id")
            if app == "c":
                conn.execute("PRAGMA user_version=1")
        env = os.environ | fixture_env() | {
            "HTTP_PORT": str(PORT), "TARGET_PORT": str(PORT+1), "HOST": "127.0.0.1",
            "PORT": str(PORT), "PUBLIC_ORIGIN": BASE, "RAILS_LOG_LEVEL": "warn",
            "DISABLE_SSL": "1", "RUST_LOG": "warn", "CAMPFIRE_LOG": "warn", "LOG_REQUESTS": "0",
            "VAPID_SUBJECT": "mailto:benchmark@example.invalid",
            "RAILS_MAX_THREADS": "5", "JOB_CONCURRENCY": "3", "CF_LOOPS": "4",
            "CF_READERS": "5", "MOJO_WORKERS": "4", "MOJO_BENCH_DIAGNOSTICS": "1", "DATABASE_PATH": str(db),
            "CAMPFIRE_DATABASE_PATH": str(db), "STORAGE_PATH": str(runtime / "files"),
            "CAMPFIRE_STORAGE_PATH": str(runtime), "CAMPFIRE_FILES_PATH": str(runtime / "files"),
            "CAMPFIRE_RESPONSE_CACHE_MB": "64" if cache else "0",
            "PUBLIC_PATH": str(MOJO / "public"),
            "CF_CACHE_BYTES": "67108864" if cache else "0",
        }
        if app == "mojo":
            binary = MOJO / "build/campfire"
            cwd = MOJO
            args = [binary]
        else:
            cwd = WORKSPACE / f"once-campfire-{app}"
            binary = cwd / ("target/release/campfire" if app == "rust" else "build/bench/campfire")
            args = [binary, "server"] if app == "rust" else [binary]
        native_app = runtime / "app"
        native_app.mkdir()
        shutil.copy2(binary, native_app / "campfire")
        if app == "c":
            shutil.copytree(cwd / "tests/fixtures/assets", native_app / "tests/fixtures/assets")
        args[0] = native_app / "campfire"
        cwd = native_app
        with (runtime / "server.log").open("w") as logfile:
            proc = subprocess.Popen(["taskset", "-c", server_cpus, *map(str,args)], cwd=cwd,
                                    env=env, stdout=logfile, stderr=logfile, start_new_session=True)
            try:
                deadline = time.monotonic() + 90
                while True:
                    if proc.poll() is not None:
                        raise RuntimeError(f"{app} exited: {(runtime/'server.log').read_text()[-5000:]}")
                    try:
                        if request("/up")[0] == 200:
                            break
                    except (OSError, http.client.HTTPException):
                        pass
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"{app} did not become ready")
                    time.sleep(0.1)
                yield db, runtime, binary
            finally:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                    proc.wait(timeout=10)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
                logfile.flush()
                shutil.copy2(runtime / "server.log", destination / "server.log")
                if verify_log:
                    validate_server_log(destination / "server.log")


def login(labels, client_cpus="4-7"):
    return loadgen("login", "--base", BASE, "--email", labels["emails.david"],
                   "--password", labels["passwords.all"], client_cpus=client_cpus)["cookie"]


def contracts(db, labels, cookie, directory):
    """Expected IDs/content are computed from fixture SQL, never from server output."""
    room, write_room = int(labels["rooms.watercooler"]), int(labels["rooms.hq"])
    anchor = int(labels["messages.busy_060"])
    user = int(labels["users.david"])
    paths = {"room_show": f"/rooms/{room}", "messages_page": f"/rooms/{room}/messages?before={anchor}",
             "sidebar": "/users/me/sidebar", "search": "/searches?q=coffee"}
    with connection(db) as conn:
        expected = {
            "room_show": [r[0] for r in conn.execute("SELECT id FROM messages WHERE room_id=? ORDER BY created_at DESC LIMIT 40", (room,))][::-1],
            "messages_page": [r[0] for r in conn.execute("SELECT id FROM messages WHERE room_id=? AND created_at<(SELECT created_at FROM messages WHERE id=?) ORDER BY created_at DESC LIMIT 40", (room,anchor))][::-1],
            "search": [r[0] for r in conn.execute("SELECT m.id FROM messages m JOIN message_search_index idx ON idx.rowid=m.id JOIN memberships mm ON mm.room_id=m.room_id WHERE mm.user_id=? AND idx.body MATCH 'coffee' ORDER BY m.id DESC LIMIT 100", (user,))][::-1],
        }
        directory.mkdir(parents=True, exist_ok=True)
        files, preflight = {}, {}
        for name, path in paths.items():
            status, headers, data, wire_bytes = request(path, cookie)
            assert status == 200, (name,status,data[:200])
            body = data.decode()
            ctype = next(v for k,v in headers.items() if k.lower()=="content-type").split(";")[0]
            contract = {"kind": name, "content_type": ctype, "required": [], "message_ids": None}
            ids = list(map(int,re.findall(r'data-message-id="(\d+)"', body)))
            if name in expected:
                assert ids == expected[name], (name,ids,expected[name])
                contract["message_ids"] = expected[name]
                contract["message_content"] = []
                for mid in expected[name]:
                    text = conn.execute("SELECT body FROM message_search_index WHERE rowid=?", (mid,)).fetchone()[0]
                    contract["message_content"].append(re.findall(r"[A-Za-z0-9_]+",text))
                    cid = conn.execute("SELECT client_message_id FROM messages WHERE id=?", (mid,)).fetchone()[0]
                    candidates = [f'id="message_{mid}"', f'id="message_{cid}"']
                    contract["required"].append(next(c for c in candidates if c in body))
            else:
                contract["required"] = ["shared_rooms"] + [html.escape(r[0], quote=True).replace("&#x27;", "&#39;") for r in conn.execute("SELECT r.name FROM rooms r JOIN memberships mm ON mm.room_id=r.id WHERE mm.user_id=? AND r.type='Rooms::Open' AND mm.involvement<>'invisible'",(user,))]
            files[name] = directory / f"{name}.json"
            write_json(files[name], contract)
            preflight[name] = {"message_ids": ids, "decoded_bytes": len(data), "wire_bytes": wire_bytes,
                               "sha256": hashlib.sha256(data).hexdigest()}
        status, _, data, _ = request(f"/rooms/{write_room}", cookie)
        assert status == 200 and b"</html>" in data
        targets = re.findall(r'id="(messages_(?:rooms_[a-z]+|room)_' + str(write_room) + r')"', data.decode())
        assert len(targets) == 1, targets
        files["post_message"] = directory / "post_message.json"
        write_json(files["post_message"], {"kind":"post_message","content_type":"text/vnd.turbo-stream.html",
                                         "required":['action="append"',f'target="{targets[0]}"']})
    return files, paths, preflight


def run_one(app, round_no, options, labels):
    dest = options.output / f"{app}-{round_no}"
    with server(app, dest, options.server_cpus, not options.no_cache, verify_log=True) as (db, runtime, binary):
        time.sleep(1)
        cookie = login(labels, options.client_cpus)
        files, paths, preflight = contracts(db, labels, cookie, dest / "contracts")
        samples, audit_files, acknowledged = [], [], 0
        write_room = int(labels["rooms.hq"])
        with connection(db) as conn:
            initial_count = conn.execute("SELECT count(*) FROM messages WHERE room_id=?",(write_room,)).fetchone()[0]
        for name in ROUTES:
            route = ["--path", paths[name]] if name in paths else ["--post-room", str(write_room), "--csrf", ""]
            for phase, duration, conc in [("warmup",options.warmup,4),("timed",options.duration,16)]:
                audit_args = []
                if name == "post_message":
                    audit = dest / f"{phase}-acknowledgements.jsonl"
                    audit_files.append(audit)
                    audit_args = ["--audit-writes",audit]
                before = os.times()
                started = time.monotonic()
                value = loadgen("http", "--base",BASE,"--cookie",cookie,*route,"--validate",files[name],
                                *audit_args,"--conc",str(conc),"--duration",str(duration),client_cpus=options.client_cpus)
                elapsed = time.monotonic() - started
                after = os.times()
                value["generator_cpu_percent"] = 100 * (after.children_user+after.children_system-before.children_user-before.children_system) / elapsed
                write_json(dest / f"{name}-{phase}.json", value)
                check_sample(value)
                if name == "post_message":
                    acknowledged += value["ok"]
                if phase == "timed":
                    samples.append(value | {"route":name})
                    print(f"{app} round {round_no}: {name}: {value['rps']:,.0f} req/s", flush=True)
        job_stats = None
        if app == "mojo":
            deadline = time.monotonic() + 30
            while True:
                status, _, raw, _ = request("/_bench/stats")
                assert status == 200
                job_stats = json.loads(raw)
                if job_stats["queued"] == job_stats["completed"]:
                    break
                assert time.monotonic() < deadline, job_stats
                time.sleep(0.02)
            assert job_stats["queued"] == acknowledged, (job_stats, acknowledged)
            assert job_stats["errors"] == job_stats["queue_full"] == job_stats["unsupported_deliveries"] == 0, job_stats
            with connection(db) as conn:
                member_count = conn.execute("SELECT count(*) FROM memberships WHERE room_id=? AND (unread_at IS NOT NULL OR connected_at>datetime('now','-60 seconds'))", (write_room,)).fetchone()[0]
                subscription_count = conn.execute("SELECT count(*) FROM push_subscriptions ps JOIN memberships mm ON mm.user_id=ps.user_id WHERE mm.room_id=? AND mm.user_id<>? AND mm.involvement='everything' AND (mm.connected_at IS NULL OR mm.connected_at<datetime('now','-60 seconds'))", (write_room, labels["users.david"])).fetchone()[0]
            assert job_stats["broadcasts"] == acknowledged, job_stats
            assert job_stats["unread_broadcasts"] == acknowledged * member_count, job_stats
            assert job_stats["notifications"] == job_stats["rejected_endpoints"] == acknowledged * subscription_count, job_stats
        audit = json.loads(command(["ruby",VERIFICATION/"bench/validate_acks.rb",db,write_room,acknowledged,*audit_files]))
        with connection(db) as conn:
            actual = conn.execute("SELECT count(*) FROM messages WHERE room_id=?",(write_room,)).fetchone()[0] - initial_count
            assert actual == acknowledged, (actual,acknowledged)
            assert conn.execute("PRAGMA integrity_check").fetchone() == ("ok",)
            assert conn.execute("SELECT count(*) FROM messages WHERE id NOT IN (SELECT rowid FROM message_search_index)").fetchone() == (0,)
        result = {"app":app,"round":round_no,"http":samples,"preflight":preflight,"post_write_audit":audit,
                  "persisted_writes":actual,"background_jobs":job_stats,"binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest()}
    result["server_log_gate"] = {"passed": True}
    write_json(dest / "result.json", result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apps",default="rust,c,mojo")
    parser.add_argument("--rounds",type=int,default=3)
    parser.add_argument("--duration",type=int,default=8)
    parser.add_argument("--warmup",type=int,default=2)
    parser.add_argument("--server-cpus",default="0-3")
    parser.add_argument("--client-cpus",default="4-7")
    parser.add_argument("--no-cache",action="store_true")
    parser.add_argument("--output",type=Path,required=True)
    args = parser.parse_args()
    apps = args.apps.split(",")
    assert set(apps) <= {"rust","c","mojo"} and len(set(apps)) == len(apps)
    assert args.rounds>0 and args.duration>0 and args.warmup>0
    assert not args.output.exists(), "Use a fresh results directory"
    args.output.mkdir(parents=True)
    # Every comparison is gated by fresh differential responses, shared sessions,
    # persisted side effects and audited background work, before timing begins.
    gate_output = command(["python3", MOJO / "tests/parity.py"], env=os.environ | {"PARITY_RESULTS": str(args.output.resolve()/"parity")})
    print(gate_output.strip(), flush=True)
    parity = json.loads((args.output/"parity/comparison.json").read_text())
    assert parity["passed"]
    labels = json.loads((SEED / "labels.json").read_text())
    original_hash = hashlib.sha256((SEED/"db/production.sqlite3").read_bytes()).hexdigest()
    metadata = {"started_at_utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"platform":os.uname()._asdict() if hasattr(os.uname(),"_asdict") else list(os.uname()),
                "server_cpus":args.server_cpus,"client_cpus":args.client_cpus,"concurrency":16,
                "rounds":args.rounds,"duration_seconds":args.duration,"warmup_seconds":args.warmup,
                "seed_sha256":original_hash,"gzip":True,"response_cache_mib":0 if args.no_cache else 64,
                "database_filesystem":"Linux VM native /tmp; identical fixture copies", "complete":False,
                "mojo_source_sha256":{str(p.relative_to(MOJO)):hashlib.sha256(p.read_bytes()).hexdigest() for folder,pattern in [("src","*.mojo"),("native","*.c"),("bench","*.py")] for p in (MOJO/folder).glob(pattern)},
                "scope":"Five matched HTTP workloads: full normalized DOM, signed sessions, text persistence/unread effects, notification preparation and guarded local endpoint rejection; zero Cable subscribers",
                "parity_gate":parity,"log_requests":False,"rust_log_filter":"warn",
                "topology":{"rust":{"processes":1,"readers":5,"job_workers":3},"c":{"processes":1,"loops":4,"readers":5},"mojo":{"http_processes":4,"job_processes":3,"sqlite_connections_per_process":1}},
                "loadgen_sha256":hashlib.sha256(LOADGEN.read_bytes()).hexdigest(),"revisions":{}}
    for name in ["once-campfire","once-campfire-c","once-campfire-rust","once-campfire-verification","once-campfire-mojo"]:
        metadata["revisions"][name] = command(["git","-C",WORKSPACE/name,"rev-parse","HEAD"]).strip()
    write_json(args.output/"metadata.json",metadata)
    results = []
    for round_no in range(1,args.rounds+1):
        order = apps if round_no%2 else apps[::-1]
        for app in order:
            results.append(run_one(app,round_no,args,labels))
    assert hashlib.sha256((SEED/"db/production.sqlite3").read_bytes()).hexdigest()==original_hash
    summary = {app:{route:{"median_rps":statistics.median(v["rps"] for r in results if r["app"]==app for v in r["http"] if v["route"]==route),
                          "runs":[v["rps"] for r in results if r["app"]==app for v in r["http"] if v["route"]==route]}
                    for route in ROUTES} for app in apps}
    metadata["complete"] = True
    write_json(args.output/"metadata.json",metadata)
    write_json(args.output/"summary.json",{"metadata":metadata,"results":summary})
    print(json.dumps(summary,indent=2))


if __name__ == "__main__":
    main()
