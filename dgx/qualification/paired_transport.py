#!/usr/bin/env python3
"""Private offline-by-default production-relay acceptance driver.

--run launches only an owned Go relay with SYNTHETIC native IPC and private ASR.
It never invokes Core Audio, plays audio, changes UI, or persists PCM.
Optional root-reviewed retention stores fixed-fictional hypotheses privately only.
"""
import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import subprocess
import threading
import time
import uuid
import wave

SOURCES = ("microphone", "call_audio")
HEADER = struct.Struct(">4s16sB3sQQQI")
FRAME_SAMPLES = 1600
RATE = 16000
SAMPLE_NS = 62500
PINNED_MANIFEST_SHA256 = '15401b2b55e0f927003cf04c94230fa3532ff0ce211e6c4a3f0612a3e363946c'


STOP_REASONS = frozenset(('user','muted','no_clients','max_duration','shutdown','capture_failure','backend_failure','native_failure','budget_rotation','rotation_limit','drain_timeout'))
GRPC_CODES = frozenset(('OK','Canceled','Unknown','InvalidArgument','DeadlineExceeded','NotFound','AlreadyExists','PermissionDenied','ResourceExhausted','FailedPrecondition','Aborted','OutOfRange','Unimplemented','Internal','Unavailable','DataLoss','Unauthenticated'))
DETAIL_CLASSES = {'operation failed':'operation_failed','operation timed out':'timeout','native owner disconnected':'native_disconnected'}

ROLLOVER_STAGES=frozenset(['boundary_clock', 'buffer_accept', 'old_transcript_validation', 'old_end_source', 'old_settlement', 'successor_open', 'successor_ready', 'successor_continue', 'replay', 'continuation_attestation'])
ROLLOVER_CAUSES=frozenset(['remote_close_normal','remote_close_going_away','remote_close_abnormal','remote_close_policy','remote_close_backend','remote_close_other','admission_deadline', 'buffer_closed', 'continuation_unproven', 'cursor_does_not_cover_cut', 'cut_deadline', 'cut_overflow', 'deadline', 'done_before_sources', 'first_frame_cursor_mismatch', 'frame_before_remote_origin', 'handoff_deadline', 'interrupted', 'invalid_pcm', 'invalid_source_completion', 'missing_cut_ledger', 'missing_native_timeline', 'missing_paired_cursors', 'missing_remote_origin', 'missing_source_ledgers', 'native_clock_mismatch', 'native_clock_overflow', 'native_disconnected', 'network_timeout', 'network_failure', 'native_host_overflow', 'native_ledger_gap', 'native_ledger_overflow', 'native_provenance_mismatch', 'native_sample_offset_overflow', 'old_closed_unsettled', 'old_ended_before_cut', 'pcm_capacity', 'remote_done_before_sources', 'remote_event_queue_overflow', 'remote_generation_invalid', 'remote_transcript_fields_invalid', 'settlement_deadline', 'successor_budget_expired', 'successor_contract_changed', 'transcript_after_final', 'transcript_clipped_interval', 'transcript_empty_timeline', 'transcript_end_clock_mismatch', 'transcript_end_host_overflow', 'transcript_host_overflow', 'transcript_interval_invalid', 'transcript_offset_overflow', 'transcript_projection_overflow', 'transcript_start_after_sent', 'transcript_start_before_sent', 'transcript_start_clock_mismatch', 'transcript_start_outside_sent', 'unclassified'])

class TerminalDiagnostics:
    """Bounded numeric/enum-only evidence; arbitrary error/detail text never escapes."""
    def __init__(self):
        self.lock=threading.Lock();self.first_failure=None;self.native_stop=None
        self.first_error_terminal=None;self.last_terminal=None;self.lifecycle=[]
        self.stderr_counts={};self.stderr_bytes={'relay':0,'observer':0};self.stderr_truncated=False;self.first_rollover_terminal=None
    def failure(self,code):
        safe=code if isinstance(code,str) and re.fullmatch(r'[A-Za-z0-9_]{1,80}',code) else 'unclassified_harness_failure'
        with self.lock:
            if self.first_failure is None:self.first_failure=safe
    def phase(self,value):
        with self.lock:
            if len(self.lifecycle)<16:self.lifecycle.append(value)
    def native(self,reason,expected):
        with self.lock:
            if self.native_stop is None:self.native_stop={'reason':reason if isinstance(reason,str) and reason in STOP_REASONS else 'unclassified','expected':bool(expected)}
    def terminal(self,stop,generation,sequence):
        code=stop.get('grpc_code',0)
        code=code if type(code) is int and 0<=code<=16 else None
        reason=stop.get('reason','')
        value={'reason':reason if isinstance(reason,str) and reason in STOP_REASONS else 'unclassified','grpc_code':code,'detail_class':DETAIL_CLASSES.get(stop.get('detail',''),'unspecified') if isinstance(stop.get('detail',''),str) else 'unspecified','generation':generation if type(generation) is int and 0<=generation<=256 else None,'sequence':sequence if type(sequence) is int and 0<=sequence<(1<<64) else None}
        with self.lock:
            self.last_terminal=value
            if code not in (0,None) and self.first_error_terminal is None:self.first_error_terminal=value
    def stderr(self,source,line):
        # Inspect at most64KiB/process, continuing to drain after the budget.
        with self.lock:
            remaining=max(0,65536-self.stderr_bytes[source]);self.stderr_bytes[source]+=min(len(line),remaining)
            if len(line)>remaining:self.stderr_truncated=True
            if remaining==0:return
            text=line[:remaining].decode('utf-8','replace')
            if len(line)<=4096:
                try:record=json.loads(text)
                except (ValueError,TypeError):record=None
                fields={'event','version','stage','cause','sequence','remote_offset_ns','cut_offset_ns','native_samples','remote_samples'}
                if isinstance(record,dict) and set(record)==fields and record.get('event')=='mistt_rollover_terminal' and type(record.get('version')) is int and record.get('version')==1 and isinstance(record.get('stage'),str) and record.get('stage') in ROLLOVER_STAGES and isinstance(record.get('cause'),str) and record.get('cause') in ROLLOVER_CAUSES:
                    scalars=[record.get(k) for k in ('sequence','remote_offset_ns','cut_offset_ns')]
                    arrays=[record.get(k) for k in ('native_samples','remote_samples')]
                    if all(type(x) is int and 0<=x<(1<<64) for x in scalars) and all(isinstance(xs,list) and len(xs)==2 and all(type(x) is int and 0<=x<(1<<64) for x in xs) for xs in arrays):
                        if self.first_rollover_terminal is None:self.first_rollover_terminal=record
            match=re.search(r'\bcode\s*=\s*([A-Za-z]+)\b',text)
            if match and match.group(1) in GRPC_CODES:
                key=source+':grpc_'+match.group(1);self.stderr_counts[key]=self.stderr_counts.get(key,0)+1
    def snapshot(self):
        with self.lock:return {'first_harness_failure':self.first_failure,'first_rollover_terminal':self.first_rollover_terminal,'first_native_stop':self.native_stop,'first_error_terminal':self.first_error_terminal,'last_terminal':self.last_terminal,'lifecycle':list(self.lifecycle),'stderr_code_counts':dict(self.stderr_counts),'stderr_inspected_bytes':dict(self.stderr_bytes),'stderr_budget_exceeded':self.stderr_truncated}


def valid_continuation(proof,previous,native,last_cut):
    try:
        if (not isinstance(proof,dict) or proof.get('version')!=1
                or proof.get('previous_session_id')!=previous
                or proof.get('native_session_id')!=native):
            return False
        cut=int(proof['cutover_offset_ns']);sources=proof['sources']
        if cut<=last_cut or len(sources)!=2:return False
        for source,name in zip(sources,SOURCES):
            sample=int(source['start_sample']);offset=int(source['capture_offset_ns'])
            if source['source']!=name or sample<=0 or offset!=sample*SAMPLE_NS or offset!=cut:return False
        return True
    except (KeyError,ValueError,TypeError):
        return False


def matching_listener_inode(lines, inodes, port):
    for line in lines:
        fields=line.split()
        if (len(fields)>9 and fields[1]==f'0100007F:{port:04X}'
                and fields[3]=='0A' and fields[9] in inodes):
            return True
    return False


def owns_linux_listener(pid, port):
    """Require a LISTEN socket inode held by this exact live owned child PID."""
    try:
        inodes=set()
        for fd in (Path('/proc')/str(pid)/'fd').iterdir():
            try:
                target=os.readlink(fd)
            except OSError:
                continue
            if target.startswith('socket:[') and target.endswith(']'):
                inodes.add(target[8:-1])
        # Loopback IPv4 only; no namespace/host listener proxy is admitted.
        return matching_listener_inode(Path('/proc/net/tcp').read_text().splitlines()[1:],inodes,port)
    except (OSError, ValueError):
        return False
    return False


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def private_file(path):
    path = Path(path)
    if not path.is_absolute():
        raise ValueError("absolute private path required")
    mode = path.lstat().st_mode
    if stat.S_ISLNK(mode) or not stat.S_ISREG(mode) or mode & 0o077:
        raise ValueError("private regular file required")
    return path


def fixture_data(manifest):
    manifest = Path(manifest)
    if not manifest.is_absolute() or digest(manifest) != PINNED_MANIFEST_SHA256:
        raise ValueError("fixed manifest hash mismatch")
    items = json.loads(manifest.read_text())
    if not isinstance(items, list) or len(items) != 12:
        raise ValueError("fixed twelve-fixture manifest required")
    result = []
    for item in items:
        path = manifest.parent / item["file"]
        if path.resolve().parent != manifest.parent.resolve() or path.is_symlink() or digest(path) != item["sha256"]:
            raise ValueError("fixture custody mismatch")
        with wave.open(str(path), "rb") as wav:
            if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getcomptype()) != (1, 2, RATE, "NONE"):
                raise ValueError("fixture geometry mismatch")
            pcm = wav.readframes(wav.getnframes())
        if len(pcm) != item["audio_samples"] * 2:
            raise ValueError("fixture sample count mismatch")
        if not 0 < item["speech_end_ms"] <= item["audio_samples"] * 1000 / RATE:
            raise ValueError("invalid acoustic end")
        result.append(dict(item, pcm=pcm))
    return result


def validate(config):
    path = None if isinstance(config, dict) else private_file(config)
    c = config if path is None else json.loads(path.read_text())
    required = {"relay", "relay_sha256", "endpoint", "token_file", "ca_file", "listen", "expected_model", "fixture_manifest", "mode", "output_dir"}
    if not required.issubset(c) or c["mode"] not in ("baseline", "soak", "diagnostic") or not c["expected_model"]:
        raise ValueError("invalid private configuration schema")
    from urllib.parse import urlsplit
    u = urlsplit(c["endpoint"])
    if u.scheme != "wss" or u.username or u.password or u.query or u.fragment or not ipaddress.ip_address(u.hostname).is_private or u.path != "/mistt/v1/stream" or u.port is None:
        raise ValueError("private-IP WSS endpoint required")
    private_file(c["token_file"])
    if not Path(c["ca_file"]).is_absolute() or Path(c["ca_file"]).is_symlink() or not Path(c["ca_file"]).is_file():
        raise ValueError("explicit CA required")
    if not Path(c["relay"]).is_absolute() or digest(c["relay"]) != c["relay_sha256"]:
        raise ValueError("relay receipt mismatch")
    host, port = c["listen"].rsplit(":", 1)
    if host != "127.0.0.1" or not 1024 < int(port) < 65536 or int(port) == 50051:
        raise ValueError("dedicated non-default loopback listener required")
    if not Path(c["output_dir"]).is_absolute() or Path(c["output_dir"]).exists():
        raise ValueError("new absolute output directory required")
    if 'retain_fictional_hypotheses' in c and type(c['retain_fictional_hypotheses']) is not bool:
        raise ValueError('explicit fictional hypothesis retention boolean required')
    items = fixture_data(c["fixture_manifest"])
    return c, items, digest(path) if path is not None else None


def control(value):
    body = json.dumps(value, separators=(",", ":")).encode() + b"\n"
    return struct.pack(">I", len(body) + 1) + b"\x01" + body


def frame(session, source, sequence, pcm):
    start = (sequence - 1) * FRAME_SAMPLES
    body = HEADER.pack(b"MST1", uuid.UUID(session).bytes, source, bytes(3), sequence, start, start * SAMPLE_NS, FRAME_SAMPLES) + pcm
    return struct.pack(">I", len(body) + 1) + b"\x02" + body


def reference_span(text, reference):
    # Compare existing model words only. Never insert punctuation or join sessions.
    words = list(re.finditer(r"[^\W_]+", text, re.UNICODE))
    actual = [m.group().casefold() for m in words]
    expected = re.findall(r"[^\W_]+", reference.casefold(), re.UNICODE)
    for i in range(len(actual) - len(expected) + 1):
        if actual[i:i + len(expected)] == expected:
            end = i + len(expected)
            last = words[end].start() if end < len(words) else len(text)
            return text[words[i].start():last].count("?")
    return None


def normalize(text):
    return " ".join(re.findall(r"[^\W_]+", text.lower(), flags=re.UNICODE))


def canonical_date(text):
    # Exact restricted q03 rule from reviewed candidate worker 8e15fde.
    normalized = normalize(text)
    normalized = re.sub(r"\bmarch (fifth|5th|five|5)\b", "march 5", normalized)
    return re.sub(r"\b(twenty twenty four|two thousand twenty four|2024)\b", "2024", normalized)


def edit_distance(expected, actual):
    row = list(range(len(actual) + 1))
    for i, word in enumerate(expected, 1):
        nxt = [i]
        for j, other in enumerate(actual, 1):
            nxt.append(min(nxt[-1] + 1, row[j] + 1, row[j-1] + (word != other)))
        row = nxt
    return row[-1]


def discard(stream):
    for _ in stream:
        pass


class Driver:
    def __init__(self, c, items, config_hash):
        self.c, self.items = c, items
        self.duration = {"baseline":119,"soak":900,"diagnostic":240}[c["mode"]]
        slots = [(i * 10.0, x) for i, x in enumerate(items)] if c["mode"] == "baseline" else [(108.5 + 110 * i, x) for i, x in enumerate([x for x in items if x["reference"].count("?") == 1][:(2 if c["mode"]=="diagnostic" else 8)])]
        self.schedule = [(int(t * RATE), x) for t, x in slots]
        if c['mode'] in ('soak','diagnostic'):
            by_id={item['id']:item for item in items}
            self.schedule += [(int(t*RATE),by_id[fixture_id]) for t,fixture_id in
                              zip((2,20,40,70),('q01','q10','q11','q12'))]
            self.schedule.sort(key=lambda row:row[0])
        self.processed_observations = {}
        self.unchanged_advanced_events = 0
        self.max_unchanged_coverage_ns = 0
        self.metrics = {x["id"]: {"fixture_id": x["id"], "reference_questionmarks": x["reference"].count("?"), "imperative_reference": x["reference"].split()[0].casefold() in {"please", "tell", "state", "explain", "confirm"}, "normalized_reference_observed": False, "actual_questionmarks_in_matched_span": 0} for _, x in self.schedule}
        self.write_lock = threading.Lock()
        self.metric_lock = threading.Lock()
        self.stopping = threading.Event()
        self.started = threading.Event()
        self.producer_done = threading.Event()
        self.abort = threading.Event()
        self.final_stop = threading.Event()
        self.start_time = None
        self.native_id = None
        self.sequence = 0
        self.native_starts = self.native_stops = self.sessions = self.rotations = self.gaps = 0
        self.current_asr_id = None
        self.current_stop = None
        self.continuation_proofs = 0
        self.last_cut = 0
        self.mic_nonmarker = 0
        self.qcounts = {}
        self.latest = ("", None)
        self.snapshots = {0: ("", None)}
        self.stop_observed = threading.Event()
        self.errors = []
        self.diagnostics=TerminalDiagnostics()
        self.terminal_drain_observed=False
        self.normal_stop_requested=False
        self.exit_before_cleanup={}
        self.process = self.subscriber = self.producer = None
        self.hypothesis_log = None
        self.hypothesis_bytes = 0
        self.hypothesis_records = 0
        self.last_retained_hypothesis = {}

        self.out = Path(c["output_dir"])
        self.out.mkdir(mode=0o700)
        self.log = (self.out / "events.jsonl").open("x", buffering=1)
        os.chmod(self.out / "events.jsonl", 0o600)
        if c.get('retain_fictional_hypotheses',False):
            fd=os.open(self.out/'fictional-hypotheses.jsonl',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600)
            self.hypothesis_log=os.fdopen(fd,'w')

        with (self.out / "intent.json").open("x") as f:
            json.dump({"operation_id": str(uuid.uuid4()), "mode": c["mode"], "relay_sha256": c["relay_sha256"], "config_sha256": config_hash, "manifest_sha256": digest(c["fixture_manifest"]), "duration_seconds": self.duration, "native_kind": "synthetic_ipc_NOT_actual_mac_capture", "fixture_count": len(self.schedule), "fictional_hypothesis_retention": self.hypothesis_log is not None}, f, indent=2)
        os.chmod(self.out / "intent.json", 0o600)

    def emit(self, event, **fields):
        with self.metric_lock:
            self.log.write(json.dumps({"event": event, "monotonic_ns": time.monotonic_ns(), **fields}) + "\n")

    def retain_hypothesis(self,value,text):
        if self.hypothesis_log is None:return
        payload=value.get('Payload',{}).get('Transcription',{})
        key=(value.get('session_id'),payload.get('source'))
        if self.last_retained_hypothesis.get(key)==text and not payload.get('is_final',False):return
        entry={'synthetic_only':True,'elapsed_ms':round((time.monotonic()-self.start_time)*1000,3),
               'session_id':value.get('session_id'),'generation':self.sessions,
               'source':payload.get('source'),'source_event_sequence':payload.get('source_event_sequence'),
               'start_sample':payload.get('start_sample'),'end_sample':payload.get('end_sample'),
               'start_offset_ns':payload.get('start_offset_ns'),'end_offset_ns':payload.get('end_offset_ns'),
               'is_final':payload.get('is_final',False),'raw_hypothesis':text}
        body=json.dumps(entry,ensure_ascii=False)+'\n'
        size=len(body.encode())
        if self.hypothesis_bytes+size>16*1024*1024:
            self.fail('fictional_hypothesis_budget_exceeded');return
        self.hypothesis_log.write(body);self.hypothesis_log.flush()
        self.hypothesis_bytes+=size;self.hypothesis_records+=1
        self.last_retained_hypothesis[key]=text

    def fail(self, code):
        self.diagnostics.failure(code)
        self.errors.append(code)
        self.abort.set()
        self.emit("failure", code=code)

    def write(self, data):
        with self.write_lock:
            self.process.stdin.write(data)
            self.process.stdin.flush()

    def pcm(self, start):
        data = bytearray(FRAME_SAMPLES * 2)
        for origin, item in self.schedule:
            lo, hi = max(start, origin), min(start + FRAME_SAMPLES, origin + item["audio_samples"])
            if lo < hi:
                data[(lo - start) * 2:(hi - start) * 2] = item["pcm"][(lo - origin) * 2:(hi - origin) * 2]
        return data

    def produce(self):
        self.start_time = time.monotonic()
        self.started.set()
        try:
            for sequence in range(1, self.duration * 10 + 1):
                due = self.start_time + sequence / 10
                if self.stopping.wait(max(0, due - time.monotonic())):
                    break
                lag = (time.monotonic() - due) * 1000
                if lag > 500:
                    self.fail("producer_lag_over_500ms")
                    break
                start = (sequence - 1) * FRAME_SAMPLES
                if self.c["mode"] == "baseline" and start and start % (10 * RATE) == 0:
                    self.snapshots[start // (10 * RATE)] = self.latest
                self.write(frame(self.native_id, 1, sequence, bytes(FRAME_SAMPLES * 2)) + frame(self.native_id, 2, sequence, self.pcm(start)))
                self.sequence = sequence
        except Exception:
            self.fail("native_pipe_write_failed")
        finally:
            self.producer_done.set()

    def native_controls(self):
        try:
            for line in self.process.stdout:
                value = json.loads(line)
                kind = value.get("type")
                if kind == "heartbeat":
                    self.write(control({"type": "heartbeat", "counter": value["counter"]}))
                elif kind == "capture_start":
                    self.native_starts += 1
                    if self.native_starts != 1:
                        self.fail("native_restarted_during_continuous_capture")
                        continue
                    self.native_id = value["session_id"]
                    self.epoch = time.monotonic_ns()
                    self.write(control({"type": "capture_started", "request_id": value["request_id"], "session_id": self.native_id, "capture_epoch_host_ns": self.epoch, "capture_epoch_unix_ms": int(time.time() * 1000), "sources": value["sources"], "microphone_ready": True, "call_audio_ready": True}))
                    self.producer = threading.Thread(target=self.produce, daemon=True)
                    self.producer.start()
                elif kind == "capture_stop":
                    self.native_stops += 1
                    self.diagnostics.native(value.get("reason"),self.normal_stop_requested)
                    self.diagnostics.phase("native_stop_received")
                    if not self.final_stop.is_set():
                        self.fail("premature_native_stop")
                    self.stopping.set()
                    if self.producer:
                        self.producer.join(2)
                        if self.producer.is_alive():
                            self.fail("producer_did_not_stop")
                            return
                    total = self.sequence * FRAME_SAMPLES
                    self.write(control({"type": "capture_stopped", "request_id": value["request_id"], "session_id": self.native_id, "cutoff_host_ns": self.epoch + total * SAMPLE_NS, "microphone_io_stopped": True, "tap_io_stopped": True, "tap_destroyed": True, "aggregate_destroyed": True}))
                    for source in SOURCES:
                        self.write(control({"type": "source_end", "session_id": self.native_id, "source": source, "last_sequence": self.sequence, "total_samples": total}))
                    self.diagnostics.phase("native_eof_sent")
                    self.emit("synthetic_native_eof", frames_per_source=self.sequence, samples_per_source=total)
        except Exception:
            if self.process.poll() is None:
                self.fail("native_control_decode_or_write_failed")

    def observations(self):
        try:
            for line in self.subscriber.stdout:
                value = json.loads(line)
                payload = value.get("Payload", {})
                if "SessionStarted" in payload:
                    if self.sessions:
                        proof=payload['SessionStarted'].get('capture_continuation')
                        if self.c['mode'] not in ('soak','diagnostic') or self.current_stop!='budget_rotation' or not valid_continuation(proof,self.current_asr_id,self.native_id,self.last_cut):
                            self.fail('continuation_attestation_unqualified')
                        else:
                            self.continuation_proofs+=1
                            self.last_cut=int(proof['cutover_offset_ns'])
                    self.current_asr_id=value.get('session_id')
                    self.current_stop=None
                    self.sessions += 1
                    model = payload["SessionStarted"].get("model", "")
                    self.emit("asr_session_started", generation=self.sessions, model=model)
                    if model != self.c["expected_model"]:
                        self.fail("unexpected_model_identity")
                elif "SessionStopped" in payload:
                    reason = payload["SessionStopped"].get("reason", "")
                    self.diagnostics.terminal(payload["SessionStopped"],self.sessions,value.get("sequence",0))
                    if value.get('session_id')==self.current_asr_id:self.current_stop=reason
                    self.rotations += reason == "budget_rotation"
                    if reason != "budget_rotation":
                        self.stop_observed.set()
                    self.emit("asr_session_stopped", generation=self.sessions, reason=reason if isinstance(reason,str) and reason in STOP_REASONS else "unclassified",grpc_code=payload["SessionStopped"].get("grpc_code",0))
                elif "SessionGap" in payload:
                    self.gaps += 1
                    self.emit("subscriber_gap", generation=self.sessions)
                elif "Transcription" in payload:
                    t = payload["Transcription"]
                    text = t.get("text", "")
                    self.retain_hypothesis(value,text)  # Only explicitly opted-in fictional snapshots persist privately.
                    source = t.get("source")
                    if source == "microphone":
                        words = set(re.findall(r"[^\W_]+", text.casefold()))
                        self.mic_nonmarker += bool(words - {"silence", "no", "speech", "audio", "blank"})
                        continue
                    if source != "call_audio" or self.start_time is None:
                        continue
                    observed_end=int(t.get("end_offset_ns",0))
                    key=(value.get("session_id"),t.get("source"))
                    previous=self.processed_observations.get(key)
                    if previous and observed_end<previous[1]:
                        self.fail("processed_coverage_regressed")
                    if text and not t.get("is_final",False):
                        if previous and normalize(text)==normalize(previous[0]) and observed_end>previous[1]:
                            self.unchanged_advanced_events+=1
                            self.max_unchanged_coverage_ns=max(self.max_unchanged_coverage_ns,observed_end-previous[1])
                        self.processed_observations[key]=(text,observed_end)
                    self.latest = (text, value.get("session_id"))
                    key = (value.get("session_id"), t.get("segment_id"))
                    count = text.count("?")
                    if count != self.qcounts.get(key, 0):
                        self.emit("literal_questionmark_count", generation=self.sessions, count=count, source_event_sequence=t.get("source_event_sequence", 0), end_sample=t.get("end_sample", 0), final=t.get("is_final", False))
                        self.qcounts[key] = count
                    for origin, item in self.schedule:
                        if t.get("end_sample", 0) < origin:
                            continue
                        marks = reference_span(text, item["reference"])
                        if marks is None:
                            continue
                        metric = self.metrics[item["id"]]
                        elapsed = (time.monotonic() - self.start_time) * 1000
                        end = origin * 1000 / RATE + item["speech_end_ms"]
                        if not metric["normalized_reference_observed"]:
                            metric.update(normalized_reference_observed=True, raw_reference_tail_ms=round(elapsed - end, 3), usable_reference_tail_ms=round(max(0, elapsed - end), 3), asr_generation=self.sessions)
                            self.emit("reference_observed", fixture_id=item["id"], raw_tail_ms=metric["raw_reference_tail_ms"], usable_tail_ms=metric["usable_reference_tail_ms"], generation=self.sessions)
                        metric["actual_questionmarks_in_matched_span"] = max(metric["actual_questionmarks_in_matched_span"], marks)
                        if marks and "qmark_after_full_reference_ms" not in metric:
                            metric["qmark_after_full_reference_ms"] = round(max(0, elapsed - end), 3)
                            self.emit("questionmark_after_full_reference", fixture_id=item["id"], count=marks, usable_tail_ms=metric["qmark_after_full_reference_ms"])
        except Exception:
            self.fail("transcription_event_decode_failed")

    def cli(self, verb):
        if not self.owns_listener():
            raise RuntimeError("listener_not_owned")
        return subprocess.run([self.c["relay"], verb, "--address", self.c["listen"]], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20, check=True)

    def owns_listener(self):
        if self.process.poll() is not None:
            return False
        port = int(self.c["listen"].rsplit(":", 1)[1])
        return owns_linux_listener(self.process.pid, port)

    def setup_stack(self):
        pass  # Transport-only; no Copilot/SubQ/SQLite or external credentials.

    def launch_bridge(self):
        pass

    def close_stack(self):
        pass

    def stderr_diagnostics(self,stream,source):
        for line in iter(lambda:stream.readline(4096),b""):
            self.diagnostics.stderr(source,line)

    def run(self):
        threads = []
        try:
            self.setup_stack()
            host, port = self.c["listen"].rsplit(":", 1)
            with socket.socket() as probe:
                probe.bind((host, int(port)))
            env = {k: v for k, v in os.environ.items() if not k.startswith("MISTT_")}
            continuous = self.c["mode"] in ("soak","diagnostic")
            env.update(MISTT_LISTEN=self.c["listen"], MISTT_DGX_ENDPOINT=self.c["endpoint"], MISTT_TOKEN_FILE=self.c["token_file"], MISTT_CA_FILE=self.c["ca_file"], MISTT_LANGUAGE="en", MISTT_BUDGET_ROTATION=str(continuous).lower(), MISTT_CONTINUOUS_ROLLOVER=str(continuous).lower(), MISTT_MAX_DURATION=str(self.duration + 30) + "s")
            relay_command=[self.c["relay"],"run"]
            if self.c["mode"]=="diagnostic":relay_command.append("--redacted-rollover-diagnostics")
            self.process = subprocess.Popen(relay_command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
            stderr_reader=threading.Thread(target=self.stderr_diagnostics,args=(self.process.stderr,"relay"),daemon=True);stderr_reader.start();threads.append(stderr_reader)
            controller = threading.Thread(target=self.native_controls, daemon=True); controller.start(); threads.append(controller)
            until = time.monotonic() + 5
            while not self.owns_listener():
                if time.monotonic() > until:
                    raise RuntimeError("owned_listener_unavailable")
                time.sleep(.05)
            self.subscriber = subprocess.Popen([self.c["relay"], "transcribe", "--address", self.c["listen"]], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            observer_stderr=threading.Thread(target=self.stderr_diagnostics,args=(self.subscriber.stderr,"observer"),daemon=True);observer_stderr.start();threads.append(observer_stderr)
            observer = threading.Thread(target=self.observations, daemon=True); observer.start(); threads.append(observer)
            until = time.monotonic() + 5
            self.launch_bridge()
            while json.loads(self.cli("status").stdout).get("connected_clients", 0) < 1:
                if time.monotonic() > until:
                    raise RuntimeError("subscriber_unavailable")
                time.sleep(.05)
            self.cli("unmute")  # One deliberate mutation; never retry.
            until = time.monotonic() + self.duration + 195
            while not self.producer_done.wait(.2):
                if self.abort.is_set() or self.process.poll() is not None or self.subscriber.poll() is not None or time.monotonic() > until:
                    raise RuntimeError("bounded_run_interrupted")
            if self.abort.is_set():
                raise RuntimeError("run_already_failed")
            self.final_stop.set()
            self.normal_stop_requested=True
            self.cli("mute")  # One deliberate mutation; never retry.
            until = time.monotonic() + 10
            while True:
                status = json.loads(self.cli("status").stdout)
                if status.get("muted") and not status.get("capturing"):
                    break
                if time.monotonic() > until:
                    raise RuntimeError("stop_not_settled")
                time.sleep(.05)
            if not self.stop_observed.wait(10):
                raise RuntimeError("asr_final_stop_not_observed")
        except Exception as error:
            self.fail(type(error).__name__)  # No exception messages or raw stderr.
        finally:
            self.final_stop.set()
            self.stopping.set()
            # A native stop is a producer barrier, not an observer barrier. Keep
            # the relay/subscriber alive long enough to receive its typed terminal.
            self.exit_before_cleanup={'relay':self.process.poll() if self.process else None,'observer':self.subscriber.poll() if self.subscriber else None}
            if self.native_stops and not self.stop_observed.is_set() and self.process and self.process.poll() is None:
                self.diagnostics.phase('awaiting_terminal_after_native_stop')
                self.terminal_drain_observed=self.stop_observed.wait(10)
            else:self.terminal_drain_observed=self.stop_observed.is_set()
            if self.process and self.process.poll() is None:
                self.diagnostics.phase("relay_terminate")
                self.process.terminate()
                try:
                    self.process.wait(10)
                except subprocess.TimeoutExpired:
                    self.diagnostics.phase("relay_kill");self.process.kill(); self.process.wait(); self.errors.append("owned_relay_killed_unsettled")
            if self.subscriber and self.subscriber.poll() is None:
                self.diagnostics.phase("observer_terminate")
                self.subscriber.terminate()
                try:
                    self.subscriber.wait(3)
                except subprocess.TimeoutExpired:
                    self.subscriber.kill(); self.subscriber.wait()
            for thread in threads:
                thread.join(2)
            if self.native_starts != 1 or self.native_stops != 1 or self.gaps or self.sequence != self.duration * 10:
                self.errors.append("native_or_sample_continuity_unqualified")
            if self.c["mode"] == "soak" and (self.sessions < 9 or self.rotations < 8 or self.continuation_proofs < 8):
                self.errors.append("fewer_than_eight_rotations")
            if self.c["mode"] == "diagnostic" and (self.sessions<3 or self.rotations<2):
                self.errors.append("fewer_than_two_diagnostic_rotations")
            if self.c["mode"] == "baseline":
                self.snapshots[12] = self.latest
                for index, item in enumerate(self.items):
                    before, before_session = self.snapshots.get(index, ("", None))
                    after, after_session = self.snapshots.get(index+1, ("", None))
                    prefix, words = normalize(before).split(), normalize(after).split()
                    metric = self.metrics[item["id"]]
                    stable = (before_session is None or before_session == after_session) and words[:len(prefix)] == prefix
                    metric["isolated_stable_prefix"] = stable
                    if stable:
                        hypothesis = " ".join(words[len(prefix):])
                        reference = normalize(item["reference"])
                        exact = hypothesis == reference
                        date_only = item["id"] == "q03" and not exact and canonical_date(hypothesis) == canonical_date(reference)
                        metric.update(verbatim_exact=exact, verbatim_word_errors=edit_distance(reference.split(), hypothesis.split()), reference_word_count=len(reference.split()), restricted_date_format_only=date_only, semantic_equivalent=exact or date_only)
            if self.unchanged_advanced_events == 0 or self.max_unchanged_coverage_ns < 500_000_000:
                self.errors.append("unchanged_processed_coverage_unqualified")
            if self.hypothesis_log is not None:
                os.fsync(self.hypothesis_log.fileno());self.hypothesis_log.close()
            self.close_stack()
            summary = {"mode": self.c["mode"], "native_kind": "synthetic_ipc_NOT_actual_mac_capture", "assessment_metrics": "not measured: transport-only", "native_starts": self.native_starts, "native_stops": self.native_stops, "asr_generations": self.sessions, "budget_rotations": self.rotations, "checked_continuation_attestations": self.continuation_proofs, "subscriber_gaps": self.gaps, "frames_per_source": self.sequence, "samples_per_source": self.sequence * FRAME_SAMPLES, "microphone_pcm": "generated_zero_only", "microphone_nonmarker_events": self.mic_nonmarker, "fixtures": list(self.metrics.values()), "errors": self.errors, "terminal_diagnostics":self.diagnostics.snapshot(), "terminal_drain_observed":self.terminal_drain_observed, "exit_before_cleanup":self.exit_before_cleanup, "exit_after_cleanup":{"relay":self.process.returncode if self.process else None,"observer":self.subscriber.returncode if self.subscriber else None}, "diagnostic_only":self.c["mode"]=="diagnostic", "transport_qualified": not self.errors and self.c["mode"]!="diagnostic", "semantic_qualified": all(m.get("semantic_equivalent", False) for m in self.metrics.values()) if self.c["mode"] == "baseline" else False, "all_references_observed_in_one_asr_segment": all(m["normalized_reference_observed"] for m in self.metrics.values()), "actual_native_qualified": False, "transport_observer_persisted_transcripts_or_pcm": self.hypothesis_log is not None, "fictional_hypothesis_text_retained": self.hypothesis_log is not None, "audio_PCM_retained": False, "fictional_hypothesis_records": self.hypothesis_records, "fictional_hypothesis_bytes": self.hypothesis_bytes, "unchanged_text_advanced_processed_events": self.unchanged_advanced_events, "max_unchanged_advanced_processed_ns": self.max_unchanged_coverage_ns}
            with (self.out / "summary.json").open("x") as f:
                json.dump(summary, f, indent=2)
            os.chmod(self.out / "summary.json", 0o600)
            self.log.close()
        return not self.errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config")
    parser.add_argument("--run", action="store_true", help="root-authorized live private-ASR effect; default is validation only")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        assert reference_span("Please confirm the fictional date.", "Please confirm the fictional date.") == 0
        assert reference_span("Were the fictional records received?", "Were the fictional records received?") == 1
        assert reference_span("Were the fictional records", "Were the fictional records received?") is None
        packet = frame(str(uuid.UUID(int=1)), 2, 1, bytes(3200))
        assert struct.unpack(">I", packet[:4])[0] == len(packet) - 4 and packet[4] == 2
        assert canonical_date("March fifth twenty twenty four") == canonical_date("March 5th 2024")
        assert canonical_date("not March fifth 2024") != canonical_date("March fifth 2024")
        assert canonical_date("March sixth 2024") != canonical_date("March fifth 2024")
        assert canonical_date("March fifth 2025") != canonical_date("March fifth 2024")
        assert edit_distance(["fictional", "date"], ["fictional", "date"]) == 0
        items = fixture_data("/Volumes/BuildOffload/artifacts/asr-candidate-20261108-v1/fixture-manifest.json")
        print(json.dumps({"offline_selftest": "PASS", "fixture_count": len(items), "imperative_ids": [x["id"] for x in items if x["reference"].split()[0].casefold() in {"please", "tell", "state", "explain", "confirm"}], "live_requests": False}))
        return
    if not args.config:
        parser.error("--config required")
    c, items, config_hash = validate(args.config)
    if not args.run:
        print(json.dumps({"validated": True, "mode": c["mode"], "fixtures": len(items), "duration_seconds": {"baseline":119,"soak":900,"diagnostic":240}[c["mode"]], "live_requests": False}))
        return
    raise SystemExit(0 if Driver(c, items, config_hash).run() else 1)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"validation_or_setup_rejected": True, "error_class": type(error).__name__}))
        raise SystemExit(2)
