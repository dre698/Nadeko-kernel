import re
D = "drivers/misc/mediatek/base/power/cpufreq_v1/src/mach/mt6765/"

# ---- atur di sini ----
L_TOP = 2501   # MHz puncak cluster L (stock bin SB = 2501)
L_VOLT = 101   # unit voltase pv: 96 = 1.119V, 101 = 1.150V, 109 = 1.200V (tiap +1 = +6.25mV)
# ----------------------
assert 2101 < L_TOP <= 2501 and 96 <= L_VOLT <= 109, "nilai di luar batas aman"

SEG = {"c62Tbl": "C62", "c62lyTbl": "C62LY", "c62dTbl": "C62D", "c62dlyTbl": "C62DLY"}
STOCK_TOP = {"C62": 2101, "C62LY": 2101, "C62D": 1801, "C62DLY": 1801}
STOCK_VOLT0 = {"C62": 106875, "C62LY": 111875, "C62D": 111875, "C62DLY": 111875}
OPP_VOLT = 60000 + (L_VOLT - 13) * 625  # satuan 10uV, sama dengan unit pv

PV = """
c65tTbl 16 1800 2000
c65Tbl 0 2401 2501
c65Tbl 15 400 900
c65Tbl 16 1800 2000
c65Tbl 31 300 400
c65Tbl 47 150 300
c62Tbl 15 400 900
c62Tbl 16 1500 1800
c62Tbl 31 300 400
c62Tbl 47 150 300
c62lyTbl 15 400 900
c62lyTbl 16 1500 1800
c62lyTbl 31 300 400
c62lyTbl 47 150 300
c65rTbl 0 2201 2501
c65rTbl 16 1601 2000
c62dTbl 16 1500 1800
c62dlyTbl 16 1500 1800
c65odTbl 0 2301 2501
c65odTbl 16 1800 2000
c65xTbl 0 2200 2501
c65xTbl 16 1600 2000
"""
OT = """
CPU_DVFS_FREQ0_LL_C65T 1800000 2000000
CPU_DVFS_VOLT15_VPROC_L_C65T 50000 60000
CPU_DVFS_VOLT15_VPROC_LL_C65T 50000 60000
CPU_DVFS_VOLT15_VPROC_CCI_C65T 50000 60000
CPU_DVFS_FREQ0_L_C65 2401000 2501000
CPU_DVFS_FREQ15_L_C65 400000 900000
CPU_DVFS_FREQ0_LL_C65 1800000 2000000
CPU_DVFS_FREQ15_LL_C65 300000 400000
CPU_DVFS_FREQ15_CCI_C65 150000 300000
CPU_DVFS_VOLT0_VPROC_L_C65 106875 111875
CPU_DVFS_VOLT1_VPROC_L_C65 102500 106875
CPU_DVFS_VOLT15_VPROC_L_C65 50000 60000
CPU_DVFS_VOLT0_VPROC_LL_C65 102500 111875
CPU_DVFS_VOLT1_VPROC_LL_C65 98750 106875
CPU_DVFS_VOLT2_VPROC_LL_C65 98750 102500
CPU_DVFS_VOLT7_VPROC_LL_C65 82500 83750
CPU_DVFS_VOLT8_VPROC_LL_C65 76875 80000
CPU_DVFS_VOLT9_VPROC_LL_C65 73750 76875
CPU_DVFS_VOLT10_VPROC_LL_C65 70625 73750
CPU_DVFS_VOLT11_VPROC_LL_C65 67500 70625
CPU_DVFS_VOLT12_VPROC_LL_C65 64375 67500
CPU_DVFS_VOLT13_VPROC_LL_C65 63125 64375
CPU_DVFS_VOLT14_VPROC_LL_C65 60000 63125
CPU_DVFS_VOLT15_VPROC_LL_C65 50000 60000
CPU_DVFS_VOLT0_VPROC_CCI_C65 106875 111875
CPU_DVFS_VOLT1_VPROC_CCI_C65 102500 106875
CPU_DVFS_FREQ15_L_C62 400000 900000
CPU_DVFS_FREQ0_LL_C62 1500000 1800000
CPU_DVFS_FREQ15_LL_C62 300000 400000
CPU_DVFS_FREQ15_CCI_C62 150000 300000
CPU_DVFS_VOLT1_VPROC_L_C62 102500 106875
CPU_DVFS_VOLT15_VPROC_L_C62 50000 60000
CPU_DVFS_VOLT0_VPROC_LL_C62 102500 111875
CPU_DVFS_VOLT1_VPROC_LL_C62 98750 106875
CPU_DVFS_VOLT2_VPROC_LL_C62 98750 102500
CPU_DVFS_VOLT8_VPROC_LL_C62 76875 80000
CPU_DVFS_VOLT9_VPROC_LL_C62 73750 76875
CPU_DVFS_VOLT10_VPROC_LL_C62 70625 73750
CPU_DVFS_VOLT11_VPROC_LL_C62 67500 70625
CPU_DVFS_VOLT12_VPROC_LL_C62 64375 67500
CPU_DVFS_VOLT14_VPROC_LL_C62 60000 63125
CPU_DVFS_VOLT15_VPROC_LL_C62 50000 60000
CPU_DVFS_VOLT0_VPROC_CCI_C62 106875 111875
CPU_DVFS_VOLT1_VPROC_CCI_C62 102500 106875
CPU_DVFS_FREQ0_LL_C62LY 1500000 1800000
CPU_DVFS_FREQ0_L_C65R 2201000 2501000
CPU_DVFS_FREQ0_LL_C65R 1601000 2000000
CPU_DVFS_FREQ0_LL_C62D 1500000 1800000
CPU_DVFS_FREQ0_LL_C62DLY 1500000 1800000
CPU_DVFS_FREQ0_L_C65OD 2301000 2501000
CPU_DVFS_FREQ0_LL_C65OD 1800000 2000000
CPU_DVFS_FREQ0_L_C65X 2200000 2501000
CPU_DVFS_FREQ0_LL_C65X 1600000 2000000
"""

# --- pv_table ---
f = D + "mtk_cpufreq_opp_pv_table.h"
lines = open(f).read().split("\n")
want, wantv = {}, {}
for l in PV.split("\n"):
    if l.strip():
        t, i, a, b = l.split()
        want[(t, int(i))] = (a, b)
for t, seg in SEG.items():
    want[(t, 0)] = (str(STOCK_TOP[seg]), str(L_TOP))
    wantv[(t, 0)] = ("96", str(L_VOLT))
tbl, idx, done = None, 0, 0
for n, l in enumerate(lines):
    m = re.match(r"static unsigned int (\w+)\[", l)
    if m:
        tbl, idx = m.group(1), 0
        continue
    r = re.match(r"(\s*\{\s*)(\d+)(,\s*)(\d+)(,.*)", l)
    if r and tbl:
        k = (tbl, idx)
        if k in want:
            a, b = want[k]
            assert r.group(2) == a, f"{k}: freq {r.group(2)} != {a}"
            v = r.group(4)
            if k in wantv:
                va, vb = wantv[k]
                assert v == va, f"{k}: volt {v} != {va}"
                v = vb
            lines[n] = r.group(1) + b + r.group(3) + v + r.group(5)
            done += 1
        idx += 1
assert done == len(want), f"pv: {done}/{len(want)}"
open(f, "w").write("\n".join(lines))

# --- opp_table ---
f = D + "mtk_cpufreq_opp_table.h"
s = open(f).read()
chg = [l.split() for l in OT.split("\n") if l.strip()]
for seg in SEG.values():
    chg.append([f"CPU_DVFS_FREQ0_L_{seg}", str(STOCK_TOP[seg] * 1000), str(L_TOP * 1000)])
    chg.append([f"CPU_DVFS_VOLT0_VPROC_L_{seg}", str(STOCK_VOLT0[seg]), str(OPP_VOLT)])
for k, a, b in chg:
    s, n = re.subn(r"(#define %s\s+)%s\b" % (k, a), r"\g<1>" + b, s)
    assert n == 1, f"{k}: {n}"
open(f, "w").write(s)
print(f"OC patch OK: L {L_TOP}MHz @ pv{L_VOLT}, LL 1800MHz;", done, "baris pv,", len(chg), "define opp")
