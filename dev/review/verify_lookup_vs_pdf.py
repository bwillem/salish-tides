import pdfplumber, re, json, sys

# Re-extracts every chart cell from the calendar PDFs and diffs vs the JSON lookup tables.
# SRC = folder with the 3 calendar-lookup PDFs; DATA = folder with the atlas_lookup_*.json files.
# Expect for each volume: 0 value diffs, 0 missing days.
SRC="ios-production-handoff/atlas-source"
DATA="ios-production-handoff/data"

MONTHS=["January","February","March","April","May","June","July","August",
        "September","October","November","December"]
MONTHNUM={m:i+1 for i,m in enumerate(MONTHS)}
DOW=("Mon","Tue","Wed","Thu","Fri","Sat","Sun")
DAYS={1:31,2:28,3:31,4:30,5:31,6:30,7:31,8:31,9:30,10:31,11:30,12:31}

def parse_pdf(path):
    """Return grid {month:int -> {day:int -> [24 charts, None for DST gap]}}"""
    grid={}
    with pdfplumber.open(path) as pdf:
        for p in pdf.pages:
            t=p.extract_text() or ""
            lines=t.split("\n")
            if not lines: continue
            month=None
            for ln in lines[:3]:
                s=ln.strip()
                if s in MONTHNUM: month=MONTHNUM[s]; break
            if month is None: continue
            grid.setdefault(month,{})
            for ln in lines:
                toks=ln.split()
                day=None; rest=None
                # case A: weekday and day separate -> "Thu 1 ..."
                di=next((i for i,tk in enumerate(toks) if tk in DOW),None)
                if di is not None and di+2<=len(toks) and di+1<len(toks) and re.fullmatch(r"\d{1,2}",toks[di+1]):
                    day=int(toks[di+1]); rest=toks[di+2:]
                else:
                    # case B: weekday glued to day -> "Sun11 ..."
                    gi=next((i for i,tk in enumerate(toks) if re.fullmatch(r"(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\d{1,2}",tk)),None)
                    if gi is not None:
                        m2=re.fullmatch(r"[A-Za-z]{3}(\d{1,2})",toks[gi])
                        day=int(m2.group(1)); rest=toks[gi+1:]
                if day is not None:
                    if day<1 or day>DAYS[month]: continue
                    # charts are bare ints; stop if a time token (with ':') appears
                    charts=[]
                    for x in rest:
                        if ":" in x: break
                        if re.fullmatch(r"\d{1,3}",x): charts.append(int(x))
                        else: break
                    # DST: March 8 has 23 values -> insert None at hour index 2
                    if month==3 and day==8 and len(charts)==23:
                        charts=charts[:2]+[None]+charts[2:]
                    grid[month][day]=charts
    return grid

def load_handoff(fn):
    d=json.load(open(f"{DATA}/{fn}"))
    g={}
    for m in d['grid']:
        if not m.isdigit(): continue
        g[int(m)]={}
        for day in d['grid'][m]:
            if day=="0": continue
            g[int(m)][int(day)]=d['grid'][m][day]
    return g, d

def compare(tag, pdf_path, fn):
    print(f"\n===== {tag} =====")
    pg=parse_pdf(pdf_path)
    hg,meta=load_handoff(fn)
    diffs=0; lenmismatch=0; missing_in_handoff=[]; total_cells=0; examples=[]
    for m in range(1,13):
        for day in range(1,DAYS[m]+1):
            prow=pg.get(m,{}).get(day)
            hrow=hg.get(m,{}).get(day)
            if prow is None:
                continue  # parser failed to find -> report separately
            if hrow is None:
                missing_in_handoff.append((m,day)); continue
            if len(prow)!=len(hrow):
                lenmismatch+=1
                if len(examples)<8: examples.append(("LEN",m,day,len(prow),len(hrow)))
                continue
            for h in range(len(prow)):
                total_cells+=1
                if prow[h]!=hrow[h]:
                    diffs+=1
                    if len(examples)<8: examples.append(("VAL",m,day,h,prow[h],hrow[h]))
    # parser coverage
    parsed_days=sum(len(v) for v in pg.values())
    print(f"  parser found {parsed_days} day-rows; handoff real day-rows={sum(len(v) for v in hg.values())}")
    print(f"  cells compared={total_cells}  value-diffs={diffs}  len-mismatches={lenmismatch}")
    print(f"  days missing in handoff (present in PDF): {missing_in_handoff}")
    for e in examples: print("   eg",e)
    return diffs,lenmismatch,missing_in_handoff

compare("VOL1_3",SRC+"/Salish Sea Tidal Current Atlas Vol 1 & 3 Calendar Lookup Table 2026.pdf","atlas_lookup_2026.json")
compare("VOL2",SRC+"/Salish Sea Tidal Current Atlas Vol 2 Calendar Lookup Table 2026.pdf","atlas_lookup_vol2_2026.json")
compare("VOL4",SRC+"/Salish Sea Tidal Current Atlas Vol 4 Calendar Lookup Tables 2026.pdf","atlas_lookup_vol4_2026.json")
