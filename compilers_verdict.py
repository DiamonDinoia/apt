#!/usr/bin/env python3
"""Compiler-matrix verdict step (test_compilers.sh's collector).

Lives outside the shell heredoc so the committed selftest (--selftest) can
exercise the collector's exit status directly. Reads the shard evidence tree
the jobs wrote under $tmp (jobs/<bundle>.<baseline>/out/{report,rc,
ldd.pairs,bin.present}) and:

  - prints every job's report lines,
  - asserts the ldd sweep BOTH directions (E13): a surprise not-found fails
    as hard as a recorded exception unexpectedly resolving,
  - asserts the bin/ accounting both directions,
  - asserts the payload-readelf arch evidence for cross jobs,
  - treats MISSING output artifacts as their own FAIL class: a job that
    bailed before the sweep (e.g. its install failed) already carries a
    primary FAIL; the collector names the missing artifact and SKIPS the
    ldd/bin comparisons for it (absent evidence proves nothing either
    direction — run 34158756678 showed the old unguarded read crashing with
    FileNotFoundError and, worse, the empty fallback forged E13
    "unexpectedly resolved" rows on payloads that never installed). A job
    claiming rc=0 with no FAIL lines but without sweep evidence is a harness
    hole and fails just as hard,
  - for every bundle with recorded cutoff.ldd rows, prints the CURRENT
    measured unresolved (basename, soname) set per baseline, so an
    exceptions.json update is backed by the run transcript itself,
  - writes/verifies the clang cutoff trial row into exceptions.json (relr
    byte-preserved, whole file canonical),
  - folds in the install-UX leg's report/rc and prints the matrix + floor.

Selftest (host-side, no containers): synthetic evidence trees where a job is
missing its out/ artifacts; the collector MUST report FAIL through the real
entry path (--collect-only) with a non-zero exit and no traceback, MUST NOT
raise on any arm, and MUST NOT fire a both-directions assertion on evidence
that does not exist. A complete synthetic job MUST pass — without that arm
the control could pass by failing everything.

Usage: compilers_verdict.py ROOT TMP     # the suite verdict (rc 0/1)
       compilers_verdict.py --collect-only TMP   # collector pass/fail only
       compilers_verdict.py --selftest           # commited control (rc 0)
"""
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

# The recorded payload-readelf spellings of target machines the stock
# spelling does not cover. Numeric e_machine (manifest-measured at mirror
# time) is the identity anchor; Kalray's binutils rebrands EM_KVARC, measured
# 2026-09-05 on k1-gcc-7.5.0's payload readelf.
ARCH_ALIASES = {"KM211 KVARC processor": {"Kalray-1 Processor"}}


def ldd_diff(actual, expected):
    return sorted(set(map(tuple, actual)) - set(map(tuple, expected))), \
           sorted(set(map(tuple, expected)) - set(map(tuple, actual)))


def bin_diff(present, launcher, links, exclusions):
    exp = {launcher.split("/", 1)[1]}
    exp.update(t.split("/", 1)[1] for t in links)
    exp.update(exclusions)
    return sorted(set(present) - exp), sorted(exp - set(present))


def collect_jobs(tmp, names, bases, emit=print):
    """Per (bundle, baseline) verdicts. Returns (fails, matrix rows)."""
    fails = []

    def fail(msg):
        emit(f"FAIL  {msg}")
        fails.append(msg)

    matrix = []
    for name in names:
        for base in bases:
            d = f"{tmp}/jobs/{name}.{base}"
            meta = json.load(open(f"{d}/expect.json"))
            rp = f"{d}/out/report"
            report = open(rp).read().splitlines() if os.path.exists(rp) \
                else None
            for line in report or []:
                emit(f"     {name}/{base}: {line}")
            if report is None:
                fail(f"{name}/{base}: no out/report (the job died before "
                     "its shell wrote one — see container.log)")
                matrix.append((name, base, "DEAD"))
                continue
            if not os.path.exists(f"{d}/out/rc"):
                fail(f"{name}/{base}: container left no rc marker "
                     "(died mid-check — see container.log)")
                matrix.append((name, base, "DEAD"))
                continue
            rcv = open(f"{d}/out/rc").read().strip()
            primary = rcv != "0" or any(l.startswith("FAIL") for l in report)
            for line in report:
                if line.startswith("FAIL"):
                    fails.append(f"{name}/{base}: {line}")

            # The sweep artifacts gate the both-directions comparisons: they
            # are the ONLY evidence either direction can stand on. A job that
            # bailed early has a primary FAIL already; a job without one that
            # still lacks the artifacts is a harness hole. Both FAIL; neither
            # compares.
            pairs = []
            sweep_ok = True
            for artifact in ("ldd.pairs", "bin.present"):
                if not os.path.exists(f"{d}/out/{artifact}"):
                    cause = ("job bailed before the sweep (primary failure "
                             "above); the ldd/bin comparisons are skipped — "
                             "absent evidence proves nothing either way"
                             if primary else
                             "job claims rc=0 with no FAIL line but left no "
                             "sweep evidence — harness hole")
                    fail(f"{name}/{base}: out/{artifact} missing: {cause}")
                    sweep_ok = False
            if sweep_ok:
                p = f"{d}/out/ldd.pairs"
                pairs = [l.split("\t", 1) for l in open(p) if "\t" in l]
                bp = [(os.path.basename(f), s.strip()) for f, s in pairs]
                if len(set(map(tuple, bp))) != len(bp):
                    fail(f"{name}/{base}: ambiguous (basename, soname) "
                         f"duplicates in the sweep: {sorted(bp)}")
                surprise, missing = ldd_diff(bp, meta["expect"])
                if surprise:
                    fail(f"{name}/{base}: ldd sweep surprise not-found: "
                         f"{surprise}")
                if missing:
                    fail(f"{name}/{base}: recorded ldd exception unexpectedly "
                         f"resolved: {missing}")
                if not surprise and not missing and len(set(bp)) == len(bp):
                    emit(f"      {name}/{base}: ldd sweep exact "
                         f"({len(bp)} exception pair(s), 0 surprises)")

                present = [l.strip() for l in open(f"{d}/out/bin.present")
                           if l.strip()]
                extra, gone = bin_diff(present, meta["bin"]["launcher"],
                                       meta["bin"]["links"],
                                       meta["bin"]["exclusions"])
                if extra:
                    fail(f"{name}/{base}: bin/ names neither linked nor "
                         f"excluded: {extra}")
                if gone:
                    fail(f"{name}/{base}: dump-spec bin/ names absent from "
                         f"the payload: {gone}")
                if not extra and not gone:
                    emit(f"      {name}/{base}: all {len(present)} bin/ names "
                         "linked or excluded")

            if not meta["native"] and base == "sid" and sweep_ok:
                rd = f"{d}/out/arch.readelf"
                if not os.path.exists(rd):
                    fail(f"{name}/{base}: no payload-readelf evidence")
                else:
                    txt = open(rd).read()
                    m = re.search(r"Machine:\s*(.+)", txt)
                    em = re.search(r"emachine=(\d+)", txt)
                    machine = m.group(1).strip() if m else ""
                    want = meta["expected_arch"]
                    allowed = {want} | ARCH_ALIASES.get(want, set())
                    if machine not in allowed and not re.fullmatch(
                            r"<unknown>: 0x[0-9a-f]+", machine):
                        fail(f"{name}/{base}: Machine '{machine}' not in "
                             f"{sorted(allowed)}")
                    if not em or int(em.group(1)) != meta["target_emachine"]:
                        fail(f"{name}/{base}: e_machine "
                             f"{em and em.group(1)} != manifest "
                             f"{meta['target_emachine']}")
                    if os.path.exists(f"{d}/out/arch.objdump"):
                        if "architecture:" not in \
                                open(f"{d}/out/arch.objdump").read():
                            fail(f"{name}/{base}: payload objdump printed no "
                                 "architecture line")
                    if m and em and int(em.group(1)) == \
                            meta["target_emachine"]:
                        emit(f"      {name}/{base}: arch '{machine}' "
                             f"(e_machine {em.group(1)}) vs catalog '{want}'")
            matrix.append((name, base,
                           "ok(%s%s)" % (meta["level"],
                                         "/cutoff" if meta["cutoff"] else "")
                           if rcv == "0" and not any(
                               f.startswith(f"{name}/{base}:") for f in fails)
                           else "FAIL"))
    return fails, matrix


# ------------------------------------------------------------------ verdict

def write_cutoff_row(root, tmp, flags, emit, fail):
    """The clang cutoff trial row: written ONCE (or under --remeasure), relr
    byte-preserved, whole file canonical. Returns True when written."""
    exc = f"{root}/exceptions.json"
    raw_before = open(exc, "rb").read()
    doc = json.loads(raw_before)
    relr_before = json.dumps(doc["relr"], indent=2, sort_keys=True)
    need_row = flags["remeasure"] or "clang_cutoff" not in doc.get("cutoff",
                                                                   {})
    if not need_row:
        emit("==> cutoff: recorded row read back; probes asserted against it")
        return False
    trial = f"{tmp}/jobs/clang-3.3.sid/out/trial.facts"
    if not os.path.exists(trial):
        fail("the cutoff trial was required but clang-3.3/sid left no "
             "trial.facts (is clang-3.3 in this shard, and did the run "
             "include the sid baseline?)")
        return False
    facts = dict(l.rstrip("\n").split("=", 1) for l in open(trial)
                 if "=" in l)
    result = ("3.3: plain C link fails ('cannot find crtbegin.o': the "
              "driver predates multiversion GCC discovery; "
              "--gcc-toolchain is unrecognized); C with -B/-L "
              f"{facts.get('crtd', '?')} compiles and runs "
              f"({facts.get('injected_c', '?')}); C++ fails on "
              f"{facts.get('extras', '?').split()[-1]} headers "
              f"({facts.get('cxx_evidence', '?')})")
    today = datetime.date.today().isoformat()
    doc["cutoff"]["clang_cutoff"] = {
        "measured": today,
        "policy": "clang series ≤3.9 → L1",
        "result": result}
    canon = json.dumps(doc, indent=2, sort_keys=True) + "\n"
    open(exc, "w").write(canon)
    after = json.loads(open(exc).read())
    assert json.dumps(after["relr"], indent=2, sort_keys=True) == \
        relr_before, "the relr section moved on write"
    assert open(exc, "rb").read() == canon.encode(), \
        "exceptions.json is not canonical after write"
    emit(f"==> CUT: recorded clang_cutoff trial (measured {today}); "
         "relr section byte-identical")
    return True


def main(root, tmp):
    fails = []

    def fail(msg):
        print(f"FAIL  {msg}")
        fails.append(msg)

    flags = json.load(open(f"{tmp}/flags.json"))
    bases = open(f"{tmp}/bases").read().split()
    slice_names = [l.strip() for l in open(f"{tmp}/shard.tsv") if l.strip()]

    jfails, matrix = collect_jobs(tmp, slice_names, bases)
    fails.extend(jfails)

    # Measured-evidence leg: for every bundle the exceptions file records
    # cutoff.ldd rows for, print the CURRENT measured unresolved set per
    # baseline — the transcript an exceptions.json update cites. "not
    # measured" where the job bailed before the sweep.
    recorded = json.load(open(f"{root}/exceptions.json")) \
        .get("cutoff", {}).get("ldd", {})
    for name in sorted(set(slice_names) & set(recorded)):
        for base in bases:
            p = f"{tmp}/jobs/{name}.{base}/out/ldd.pairs"
            want = sorted(map(tuple, recorded[name]["files"]))
            if os.path.exists(p):
                bp = sorted({(os.path.basename(f), s.strip())
                             for f, s in
                             (l.split("\t", 1) for l in open(p) if "\t" in l)})
                tag = "MATCHES record" if bp == want \
                    else "DIFFERS from record"
                print(f"==> LDD-MEASURED {name}/{base}: measured {bp} "
                      f"({tag}; recorded {len(want)} pair(s))")
            else:
                print(f"==> LDD-MEASURED {name}/{base}: not measured "
                      "(job bailed before the sweep)")

    write_cutoff_row(root, tmp, flags, print, fail)

    ux = f"{tmp}/ux/report"
    if os.path.exists(ux):
        for line in open(ux):
            line = line.rstrip("\n")
            print(f"     ux: {line}")
            if line.startswith("FAIL"):
                fails.append(f"ux: {line}")
    else:
        fail("install-UX leg left no report")
    rcx = f"{tmp}/ux/rc"
    if not os.path.exists(rcx):
        fail("install-UX leg left no rc marker")
    elif open(rcx).read().strip() != "0":
        fail("install-UX leg rc != 0")

    print()
    print("== matrix (bundle x baseline -> verdict) ==")
    for name, base, res in matrix:
        print(f"  {name:34s} {base:7s} {res}")
    floor = json.load(open(f"{tmp}/floor.json"))
    print(f"== floor: {len(floor['emit_floor'])} bundles mirrored; "
          f"{floor['pending_total']} catalog payloads pending-mirror "
          f"({floor['pending_slot']} in this shard) — "
          "installed-only runs never go green on a pending entry")

    if fails:
        print()
        for f in fails:
            print(f"FAIL  {f}")
        return 1
    print(f"ALLPASS ({len(matrix)} matrix jobs + install-UX legs)")
    return 0


# ----------------------------------------------------------------- selftest

def _synthetic_meta(expect=None):
    return {"expect": expect or [],
            "bin": {"launcher": "bin/gcc", "links": ["bin/gcc-ar"],
                    "exclusions": []},
            "expected_arch": "Advanced Micro Devices X86-64",
            "target_emachine": 62,
            "smoke": "L1", "level": "L1", "cutoff": False,
            "regime": "debian", "native": True,
            "version": "16~ce16.2.0-1", "size_mib": 1}


def _write_job(tmp, name, base, meta):
    d = f"{tmp}/jobs/{name}.{base}"
    os.makedirs(d, exist_ok=True)
    json.dump(meta, open(f"{d}/expect.json", "w"))
    return d


def _collect_status(tmp):
    """The real entry path, as a trip: exit status + streams, no in-process
    shortcuts."""
    return subprocess.run([sys.executable, os.path.abspath(__file__),
                           "--collect-only", tmp],
                          capture_output=True, text=True)


def selftest() -> int:
    rc = 0

    def check(ok, msg):
        nonlocal rc
        print(("ok " if ok else "FAIL  ") + msg)
        rc |= 0 if ok else 1

    # Arm 1 (positive control): a complete synthetic job PASSES. Without this
    # arm the controls below could pass by failing everything.
    with tempfile.TemporaryDirectory() as t:
        meta = _synthetic_meta()
        d = _write_job(t, "gcc-16", "sid", meta)
        os.makedirs(f"{d}/out")
        open(f"{d}/out/report", "w").write("ok    install gcc-16\n")
        open(f"{d}/out/rc", "w").write("0")
        open(f"{d}/out/ldd.pairs", "w").close()
        open(f"{d}/out/bin.present", "w").write("gcc\ngcc-ar\n")
        open(f"{t}/shard.tsv", "w").write("gcc-16\n")
        open(f"{t}/bases", "w").write("sid\n")
        r = _collect_status(t)
        check(r.returncode == 0 and "Traceback" not in r.stderr,
              "complete synthetic job passes through --collect-only")

    # Arm 2 (the 34158756678 shape): report carries the primary install FAIL,
    # rc=1, and the sweep artifacts never existed. The collector must FAIL
    # naming the missing artifacts, MUST NOT crash, and MUST NOT forge an
    # "unexpectedly resolved" E13 row from absent evidence.
    with tempfile.TemporaryDirectory() as t:
        meta = _synthetic_meta(expect=[["go", "libgo.so.25"]])
        d = _write_job(t, "gcc-17", "sid", meta)
        os.makedirs(f"{d}/out")
        open(f"{d}/out/report", "w").write(
            "FAIL  install gcc-17=17~trunk20260904\n")
        open(f"{d}/out/rc", "w").write("1")
        open(f"{t}/shard.tsv", "w").write("gcc-17\n")
        open(f"{t}/bases", "w").write("sid\n")
        r = _collect_status(t)
        check(r.returncode != 0 and "Traceback" not in r.stderr,
              "job that bailed before the sweep: rc!=0, no traceback")
        check("out/ldd.pairs missing" in r.stdout
              and "out/bin.present missing" in r.stdout,
              "both missing artifacts are named FAIL rows")
        check("unexpectedly resolved" not in r.stdout,
              "absent evidence does not forge an E13 resolve verdict")

    # Arm 3: no out/ dir at all (container died before mounting produced
    # anything). DEAD row, no exception.
    with tempfile.TemporaryDirectory() as t:
        _write_job(t, "gcc-16", "trixie", _synthetic_meta())
        open(f"{t}/shard.tsv", "w").write("gcc-16\n")
        open(f"{t}/bases", "w").write("trixie\n")
        r = _collect_status(t)
        check(r.returncode != 0 and "Traceback" not in r.stderr
              and "no out/report" in r.stdout,
              "job with no out/ at all: DEAD verdict, no traceback")

    # Arm 4 (harness hole): rc=0, clean report, but the sweep evidence is
    # absent. A claimed pass without evidence is not a pass.
    with tempfile.TemporaryDirectory() as t:
        d = _write_job(t, "gcc-16", "sid", _synthetic_meta())
        os.makedirs(f"{d}/out")
        open(f"{d}/out/report", "w").write("ok    install gcc-16\n")
        open(f"{d}/out/rc", "w").write("0")
        open(f"{t}/shard.tsv", "w").write("gcc-16\n")
        open(f"{t}/bases", "w").write("sid\n")
        r = _collect_status(t)
        check(r.returncode != 0 and "harness hole" in r.stdout,
              "rc=0 without sweep evidence fails as a harness hole")

    # Arm 5: the sweep artifacts exist; E13 still fires both directions on
    # measured data (recorded pair missing => FAIL exactly as before).
    with tempfile.TemporaryDirectory() as t:
        meta = _synthetic_meta(expect=[["go", "libgo.so.25"]])
        d = _write_job(t, "gcc-17", "sid", meta)
        os.makedirs(f"{d}/out")
        open(f"{d}/out/report", "w").write("ok    install gcc-17\n")
        open(f"{d}/out/rc", "w").write("0")
        open(f"{d}/out/ldd.pairs", "w").close()
        open(f"{d}/out/bin.present", "w").write("gcc\ngcc-ar\n")
        open(f"{t}/shard.tsv", "w").write("gcc-17\n")
        open(f"{t}/bases", "w").write("sid\n")
        r = _collect_status(t)
        check(r.returncode != 0 and "unexpectedly resolved" in r.stdout
              and "Traceback" not in r.stderr,
              "E13 resolve assertion still fires when the sweep DID run")

    print("collector selftest:", "clean" if rc == 0 else "FAILURES above")
    return rc


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    if len(sys.argv) == 3 and sys.argv[1] == "--collect-only":
        tmp = sys.argv[2]
        bases = open(f"{tmp}/bases").read().split()
        names = [l.strip() for l in open(f"{tmp}/shard.tsv") if l.strip()]
        fails, matrix = collect_jobs(tmp, names, bases)
        for name, base, res in matrix:
            print(f"  {name:34s} {base:7s} {res}")
        sys.exit(1 if fails else 0)
    if len(sys.argv) == 3:
        sys.exit(main(sys.argv[1], sys.argv[2]))
    print(__doc__)
    sys.exit(2)
