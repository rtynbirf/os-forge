#!/usr/bin/env python3
"""Супервизор DAG ковки forge/dag.json (П44, issue #3) — std-only Python.

Идемпотентность-храповик: шаг исполняется ТОЛЬКО если
  (а) fingerprint его входов изменился с прошлого прогона, или
  (б) его выходы на диске не сходятся с пломбами forge/state.json.
Повторный прогон на том же входе = 0 исполнений и те же артефакт-хеши.

Режимы:
  python3 forge/dag_run.py plan [--root DIR] [--until ID]
      — топологический план: порядок, fingerprint входов, честные блокировки
        по отсутствующим инструментам (blocked), без исполнения.
  python3 forge/dag_run.py run [--root DIR] [--until ID] [--dry]
      — исполнение по храповику. Любая причина неотложного шага фиксируется;
        отсутствующий инструмент = честный ОТКАЗ (exit 2), не имитация.
  python3 forge/dag_run.py selftest
      — машинная проверка механизма на мини- forge во временной папке:
        прогон 2× (второй = 0 исполнений, артефакты байт-идентичны),
        подмена артефакта (сходится обратно), смена входа (детект),
        цикл в DAG (красный), отсутствующая зависимость (красный).

Выход DAG с циклом/дублями/висячими зависимостями = красный до исполнения.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

DAG_FILE = "forge/dag.json"
STATE_FILE = "forge/state.json"


def sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def load_dag(root: Path) -> dict:
    p = root / DAG_FILE
    if not p.is_file():
        raise SystemExit(f"DAG_ERROR=FAIL :: нет {DAG_FILE} в {root}")
    return json.loads(p.read_text(encoding="utf-8"))


def topo_order(steps: list[dict]) -> list[dict]:
    """Топологический порядок (Kahn) + валидация. Ошибки = SystemExit (красный)."""
    by_id = {s["id"]: s for s in steps}
    if len(by_id) != len(steps):
        raise SystemExit("DAG_ERROR=FAIL :: дубликаты id шагов")
    errs = []
    for s in steps:
        for d in s.get("depends_on", []):
            if d not in by_id:
                errs.append(f"{s['id']}: зависимость {d} не существует")
    if errs:
        raise SystemExit("DAG_ERROR=FAIL :: " + "; ".join(errs))
    indeg = {sid: 0 for sid in by_id}
    children: dict[str, list[str]] = {sid: [] for sid in by_id}
    for s in steps:
        for d in s.get("depends_on", []):
            indeg[s["id"]] += 1
            children[d].append(s["id"])
    ready = sorted([sid for sid, k in indeg.items() if k == 0])
    order = []
    while ready:
        sid = ready.pop(0)
        order.append(by_id[sid])
        for ch in sorted(children[sid]):
            indeg[ch] -= 1
            if indeg[ch] == 0:
                ready.append(ch)
        ready.sort()
    if len(order) != len(steps):
        stuck = sorted(set(by_id) - {s["id"] for s in order})
        raise SystemExit("DAG_ERROR=FAIL :: цикл в DAG, шаги вне порядка: " + ", ".join(stuck))
    return order


def glob_outputs(root: Path, pattern: str) -> list[Path]:
    if "*" in pattern:
        return sorted(root.glob(pattern))
    return [root / pattern]


def step_fingerprint(root: Path, step: dict) -> tuple[str, list[str]]:
    """sha256 от сортированного списка (relpath, sha256) входов."""
    parts, missing = [], []
    for rel in step.get("inputs", []):
        p = root / rel
        if p.is_file():
            parts.append(f"{rel}:{sha256_file(p)}")
        else:
            missing.append(rel)
    blob = "\n".join(parts).encode("utf-8")
    return hashlib.sha256(blob).hexdigest(), missing


def tool_missing(tool: str) -> bool:
    return shutil.which(tool) is None


def load_state(root: Path) -> dict:
    p = root / STATE_FILE
    if not p.is_file():
        return {"schema": "forge-state/1", "steps": {}}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {"schema": "forge-state/1", "steps": {}}


def save_state(root: Path, st: dict) -> None:
    p = root / STATE_FILE
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(st, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def outputs_status(root: Path, step: dict, rec: dict) -> tuple[bool, list[str]]:
    """True, если все заявленные выходы на диске сходятся с пломбами прогона."""
    bad = []
    cur = {}
    for pat in step.get("outputs", []):
        for p in glob_outputs(root, pat):
            if p.is_file():
                cur[p.relative_to(root).as_posix()] = sha256_file(p)
    if not cur:
        return False, ["выходы не найдены на диске"]
    old = (rec or {}).get("outputs", {})
    for rel, hx in cur.items():
        if old.get(rel) != hx:
            bad.append(f"{rel}: на диске {hx[:12]}…, пломба {str(old.get(rel))[:12]}…")
    for rel in old:
        if rel not in cur:
            bad.append(f"{rel}: пломба есть, файла нет")
    return (not bad), bad


def cmd_plan(root: Path, until: str | None) -> int:
    dag = load_dag(root)
    order = topo_order(dag["steps"])
    print(f"DAG_PLAN root={root}")
    cut = False
    for s in order:
        if until and s["id"] == until:
            cut = True
        if cut and until and s["id"] != until and False:
            pass
        fp, missing = step_fingerprint(root, s)
        blocked = [t for t in s.get("requires", []) if tool_missing(t)]
        status = "BLOCKED(tool)" if blocked else "planned"
        print(f"  {s['id']:<15} [{status}] fp={fp[:12]}…"
              + (f" missing_inputs={missing}" if missing else "")
              + (f" requires_missing={blocked}" if blocked else ""))
        if until and s["id"] == until:
            break
    print("DAG_PLAN=PASS")
    return 0


def cmd_run(root: Path, until: str | None, dry: bool) -> int:
    dag = load_dag(root)
    order = topo_order(dag["steps"])
    st = load_state(root)
    executed = skipped = 0
    stop = False
    for s in order:
        if until and s["id"] == until:
            stop = True
        rec = st["steps"].get(s["id"], {})
        fp, missing = step_fingerprint(root, s)
        blocked = [t for t in s.get("requires", []) if tool_missing(t)]
        if blocked:
            print(f"  {s['id']}: ОТКАЗ — нет инструментов: {', '.join(blocked)} "
                  f"(честный отказ: ставить шаг на паузу, не имитировать)")
            print("DAG_RUN=FAIL (blocked tool)")
            return 2
        if missing:
            print(f"  {s['id']}: ОТКАЗ — нет входов: {', '.join(missing)}")
            print("DAG_RUN=FAIL (missing input)")
            return 2
        if rec.get("fingerprint") == fp:
            ok, bad = outputs_status(root, s, rec)
            if ok:
                skipped += 1
                print(f"  {s['id']}: SKIP (храповик: входы и выходы сходятся)")
                continue
            print(f"  {s['id']}: STALE (выходы расходятся с пломбой: {bad[0]})")
        else:
            print(f"  {s['id']}: RUN (входы изменились или первый прогон)")
        if dry:
            print(f"  {s['id']}: [СУХОЙ ПРОГОН] {s.get('cmd','')}")
            continue
        env = dict(os.environ)
        r = subprocess.run(["bash", "-c", s.get("cmd", ":")], cwd=root, env=env)
        if r.returncode != 0:
            print(f"DAG_RUN=FAIL (шаг {s['id']} упал, rc={r.returncode})")
            return 1
        outs = {}
        for pat in s.get("outputs", []):
            for p in glob_outputs(root, pat):
                if p.is_file():
                    outs[p.relative_to(root).as_posix()] = sha256_file(p)
        st["steps"][s["id"]] = {"fingerprint": fp, "outputs": outs, "status": "done"}
        save_state(root, st)
        executed += 1
        if until and s["id"] == until:
            break
    print(f"DAG_RUN=PASS (executed={executed} skipped={skipped})")
    return 0


# --------------------------------------------------------------------------
# selftest: мини- forge во временной папке — механизм, а не сеть
# --------------------------------------------------------------------------
GEN_A = 'python3 -c "import hashlib,sys,pathlib;r=pathlib.Path(sys.argv[1]);d=(r/\'in.txt\').read_bytes();(r/\'out/A.txt\').write_bytes(hashlib.sha256(d).hexdigest().encode())"'
GEN_B = 'python3 -c "import hashlib,sys,site,pathlib;r=pathlib.Path(sys.argv[1]);a=(r/\'out/A.txt\').read_bytes();(r/\'out/B.txt\').write_bytes(hashlib.sha256(a).hexdigest().encode())"'
GEN_C = 'python3 -c "import hashlib,sys,pathlib;r=pathlib.Path(sys.argv[1]);a=(r/\'out/A.txt\').read_bytes();b=(r/\'out/B.txt\').read_bytes();(r/\'out/C.txt\').write_bytes(hashlib.sha256(a+b).hexdigest().encode())"'


def build_fixture(root: Path) -> dict:
    (root / "out").mkdir(parents=True)
    (root / "in.txt").write_bytes(b"forge input payload\n")
    return {
        "schema": "forge-dag/1",
        "steps": [
            {"id": "s1", "depends_on": [], "cmd": GEN_A + " .",
             "inputs": ["in.txt"], "outputs": ["out/A.txt"], "requires": ["python3"]},
            {"id": "s2", "depends_on": ["s1"], "cmd": GEN_B + " .",
             "inputs": ["out/A.txt"], "outputs": ["out/B.txt"], "requires": ["python3"]},
            {"id": "s3", "depends_on": ["s1", "s2"], "cmd": GEN_C + " .",
             "inputs": ["out/A.txt", "out/B.txt"], "outputs": ["out/C.txt"],
             "requires": ["python3"]},
        ],
    }


def run_dag_object(root: Path, dag: dict) -> tuple[int, list[str]]:
    """Прогон произвольного DAG-объекта (для selftest), вывод собирается.
    state.json НЕ сбрасываем между прогонами — храповик должен жить."""
    import io
    import contextlib
    (root / DAG_FILE).parent.mkdir(parents=True, exist_ok=True)
    (root / DAG_FILE).write_text(json.dumps(dag, ensure_ascii=False), encoding="utf-8")
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            rc = cmd_run(root, None, False)
    except SystemExit as e:
        rc, buf = 3, io.StringIO(str(e))
    return rc, buf.getvalue().splitlines()


def selftest() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="forge-dag-") as td:
        root = Path(td)
        dag = build_fixture(root)

        # 1) цикл обязан быть красным ДО исполнения
        cyc = json.loads(json.dumps(dag))
        cyc["steps"][0]["depends_on"] = ["s3"]
        try:
            topo_order(cyc["steps"])
            failures.append("цикл в DAG не пойман")
        except SystemExit:
            print("DAG_CYCLE_TEST=PASS (цикл даёт красный)")

        # 2) висячая зависимость обязана быть красной
        dang = json.loads(json.dumps(dag))
        dang["steps"][1]["depends_on"] = ["ghost"]
        try:
            topo_order(dang["steps"])
            failures.append("висячая зависимость не поймана")
        except SystemExit:
            print("DAG_DEP_TEST=PASS (висячая зависимость даёт красный)")

        # 3) первый прогон: 3 исполнения
        rc1, out1 = run_dag_object(root, dag)
        hashes1 = {p.name: sha256_file(p) for p in sorted((root / "out").glob("*.txt"))}
        if rc1 != 0 or "executed=3" not in " ".join(out1):
            failures.append(f"первый прогон: rc={rc1}, ожидалось executed=3 :: {out1}")
        else:
            print("DAG_FIRST_RUN=PASS (3 шага исполнены)")

        # 4) повторный прогон: 0 исполнений, те же артефакт-хеши
        rc2, out2 = run_dag_object(root, dag)
        hashes2 = {p.name: sha256_file(p) for p in sorted((root / "out").glob("*.txt"))}
        if rc2 != 0 or "executed=0" not in " ".join(out2):
            failures.append(f"повторный прогон исполнил шаги: {out2}")
        elif hashes1 != hashes2:
            failures.append("повторный прогон изменил артефакт-хеши")
        else:
            print("DAG_IDEMPOTENT=PASS (повтор = 0 исполнений, хеши те же)")

        # 5) подмена артефакта: храповик чинит, результат сходится к тому же
        (root / "out" / "B.txt").write_bytes(b"tampered")
        rc3, out3 = run_dag_object(root, dag)
        hashes3 = {p.name: sha256_file(p) for p in sorted((root / "out").glob("*.txt"))}
        if rc3 != 0 or hashes3 != hashes1:
            failures.append("подмена артефакта не сойдётся к исходному результату")
        else:
            print("DAG_TAMPER_REPAIR=PASS (подмена обнаружена, результат воспроизведён)")

        # 6) смена входа: детект и пересборка вниз по DAG
        (root / "in.txt").write_bytes(b"forge input payload v2\n")
        rc4, out4 = run_dag_object(root, dag)
        a4 = sha256_file(root / "out" / "A.txt")
        if rc4 != 0 or a4 == hashes1["A.txt"] or "executed=0" in " ".join(out4):
            failures.append("смена входа не привела к пересборке")
        else:
            print("DAG_INPUT_CHANGE=PASS (смена входа пересобирает граф)")

    print("--- итог selftest ---")
    if failures:
        for f in failures:
            print(f"SELFTEST_NEGATIVE=FAIL :: {f}")
        print("SELFTEST=FAIL")
        return 1
    print("SELFTEST=PASS (идемпотентность-храповик доказана машиной)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="супервизор DAG ковки OS-FORGE")
    ap.add_argument("mode", choices=["plan", "run", "selftest"])
    ap.add_argument("--root", default=None, help="корень репо (по умолчанию — репо скрипта)")
    ap.add_argument("--until", default=None, help="остановиться после шага ID")
    ap.add_argument("--dry", action="store_true", help="показать план без исполнения")
    a = ap.parse_args()
    if a.mode == "selftest":
        return selftest()
    root = Path(a.root).resolve() if a.root else Path(__file__).resolve().parents[1]
    if a.mode == "plan":
        return cmd_plan(root, a.until)
    return cmd_run(root, a.until, a.dry)


if __name__ == "__main__":
    sys.exit(main())
