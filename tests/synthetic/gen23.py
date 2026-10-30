"""Synthetic MLS export with known adjustment values (v2.3 variable set).

  python3 gen23.py <seed> <n> <path: A|B|C|D> <out.csv> <truth.json> [eff YYYY-MM-DD]

Prices are built from TRUE above-grade counts; the recorded MLS fields carry the
errors realtors make: lower-level rooms lumped into the totals with the lower-level
section left blank, driveway spots counted as garage spaces, the odd typo.
"""
import csv, json, math, random, sys, datetime

seed, N, PATH = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
OUT, TRUTH = sys.argv[4], sys.argv[5]
EFF = datetime.date.fromisoformat(sys.argv[6]) if len(sys.argv) > 6 else datetime.date(2026, 9, 15)
random.seed(seed)
START = EFF - datetime.timedelta(days=int(5.5 * 365))
MD = 30.4375

def months(d):
    return (d - START).days / MD

def path(d):
    m = months(d)
    if PATH == "A":   # strong run-up, then nearly flat
        k = months(datetime.date(2022, 4, 15)); return math.log(1.011) * min(m, k) + math.log(1.0015) * max(0, m - k)
    if PATH == "B":   # steady
        return math.log(1.004) * m
    if PATH == "C":   # flat
        return 0.0
    # D: run-up, dip, recovery
    k1, k2 = months(datetime.date(2022, 6, 1)), months(datetime.date(2023, 1, 15))
    return math.log(1.010) * min(m, k1) + math.log(0.992) * max(0, min(m, k2) - k1) + math.log(1.004) * max(0, m - k2)

def truth_parts(t):
    g = t["gla"]; lot = t["lot_sf"]; gs = t["garage"]
    return {
        "gla": 95 * min(g, 2400) + 70 * max(0, g - 2400),
        "lot_sf": 4.0 * min(lot, 20000) + 0.8 * max(0, lot - 20000),
        "beds_ag": 6000 * t["beds_ag"],
        "fb_ag": 14000 * t["fb_ag"],
        "hb_ag": 7000 * t["hb_ag"],
        "garage": 18000 * min(gs, 1) + 10000 * min(max(gs - 1, 0), 1) + 4000 * max(gs - 2, 0),
        "carport": 5000 * t["carport"],
        "pool": 20000 * t["pool"],
        "year_built": 1200 * max(0, t["year_built"] - 1980),
        "levels": 0,
    }

streets = ["Oak Ridge", "Cedar Run", "Hartley", "Meadow Bend", "Fox Hollow", "Stony Brook", "Quail Hill", "Briar Gate", "Old Mill", "Laurel Fork",
           "Sycamore", "Indian Hill", "Brook Ford", "Winter Park", "Garretson", "Natick", "Strattondale", "Battalion", "Bakersville", "Ridge Ford"]
sfx = ["Rd", "Ln", "Dr", "Ct", "Way", "Pl"]
rows, truth = [], []
span = (EFF - START).days
for i in range(N):
    gla = int(round(random.uniform(1200, 3200) / 10) * 10)
    beds = max(2, min(6, round(1.2 + gla / 800 + random.gauss(0, 0.6))))
    fb = max(1, min(4, round(0.3 + gla / 1100 + random.gauss(0, 0.5))))
    hb = random.choices([0, 1, 2], weights=[30, 62, 8])[0]
    garage = random.choices([0, 1, 2, 3], weights=[22, 18, 50, 10])[0]
    carport = random.choices([0, 1, 2], weights=[86, 9, 5])[0] if garage <= 1 else 0
    pool = 1 if random.random() < 0.10 else 0
    lot = int(min(150000, max(4000, round(math.exp(random.gauss(math.log(15000), 0.6))))))
    yb = random.randint(1965, 2015)
    levels = random.choice([2, 2, 2, 3, 3])
    finished = random.random() < 0.55
    ll_beds = (1 if random.random() < 0.40 else 0) if finished else 0
    ll_full = (1 if random.random() < 0.60 else 0) if finished else 0
    ll_half = (1 if random.random() < 0.10 else 0) if finished else 0
    t = dict(gla=gla, beds_ag=beds, fb_ag=fb, hb_ag=hb, garage=garage, carport=carport, pool=pool, lot_sf=lot, year_built=yb, levels=levels)
    parts = truth_parts(t)
    value = 60000 + sum(parts.values())
    cdate = START + datetime.timedelta(days=random.randint(0, span - 60))
    close = cdate + datetime.timedelta(days=random.randint(20, 55))
    if close >= EFF: close = EFF - datetime.timedelta(days=random.randint(3, 20))
    cond = random.choices([0.85, 1.0, 1.12], weights=[8, 84, 8])[0]   # a few dated, a few redone
    price = value * math.exp(path(close) - path(EFF)) * cond * math.exp(random.gauss(0, 0.06))
    price = int(round(price / 100) * 100)
    stype = "Standard"
    if i % 53 == 7: stype = "Bank Owned/REO"; price = int(price * 0.80)
    if i % 71 == 11: stype = "Short Sale"; price = int(price * 0.88)
    if i % 157 == 19: price = price * 10   # typo in the close price
    # what the listing says
    rec_ll = finished and random.random() < 0.78   # lower-level section filled in
    lumped = finished and not rec_ll and (ll_beds + ll_full + ll_half) > 0
    beds_tot, full_tot, half_tot = beds + ll_beds, fb + ll_full, hb + ll_half
    rec_garage = garage
    abuse = random.random() < 0.03
    if abuse: rec_garage = garage + random.randint(3, 8)
    typo = random.random() < 0.01
    if typo: beds_tot += 3
    bsmt_type = ("Fully Finished" if random.random() < 0.7 else "Partially Finished") if finished else random.choice(["Unfinished", "Full", ""])
    lotac = round(lot / 43560, 4)
    list_date = cdate - datetime.timedelta(days=random.randint(3, 60))
    rows.append({
        "MLS Number": f"DEMO{200000 + i}", "Full Street Address": f"{4000 + 3 * i} {random.choice(streets)} {random.choice(sfx)}",
        "Close Price": price, "Agreement of Sale/Signed Lease Date": cdate.isoformat(), "Close Date": close.isoformat(),
        "Listing Entry Date": list_date.isoformat(), "Above Grade Finished SQFT": gla, "Beds": beds_tot, "Bathrooms Full": full_tot,
        "Bathrooms Half": half_tot if half_tot else "",
        "Lower Levels Total Bedrooms": (ll_beds if rec_ll else ""), "Lower Levels Total Full Baths": (ll_full if rec_ll else ""),
        "Lower Levels Total Half Baths": (ll_half if rec_ll and ll_half else ""),
        "Basement": "True", "Basement Type": bsmt_type, "Below Grade Finished SQFT": random.randint(40, 120) * 10 if finished else "",
        "Garage": "True" if rec_garage else "False", "Total Garage Spaces": rec_garage if rec_garage else "",
        "Attached Carport - # of Spaces": carport if carport else "", "Pool": "Yes - Personal" if pool else random.choice(["No Pool", "No Pool", "Yes - Community"]),
        "Lot Size SqFt": lot, "Lot Size Acres": lotac, "Year Built": yb, "Levels/Stories": levels, "Zip Code": random.choice(["22015", "22015", "22015", "22039"]),
        "County": "Fairfax, VA", "Sale Type": stype, "Status": "CLS", "Tax ID": f"0{77 + i // 40}-{i % 97:02d}-{1000 + i}"
    })
    truth.append({"mls": f"DEMO{200000 + i}", "parts": parts, "value": value, "close": close.isoformat(), "lumped": lumped, "abuse": abuse, "typo": typo,
                  "cond": cond, "stype": stype})
hdr = list(rows[0].keys())
with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=hdr); w.writeheader()
    for r in rows: w.writerow(r)
json.dump({"eff": EFF.isoformat(), "path": PATH, "pathEff": path(EFF), "rows": truth,
           "pathAt": {r["mls"]: path(datetime.date.fromisoformat(r["close"])) for r in truth}}, open(TRUTH, "w"))
print("rows", len(rows), "lumped", sum(r["lumped"] for r in truth), "garage abuse", sum(r["abuse"] for r in truth))
