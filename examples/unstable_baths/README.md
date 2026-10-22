# Example: a full bath that comes out near $50,000

This is a made-up sale file, built so the **old** adjustment tool does the thing that has been showing up on real files: a full-bath adjustment around $50,000, and a different answer if you change the subject.

It is not a real market. Nothing in here is an opinion of value. The true price equation used to build the file is in `truth.json`. A full bath was given **$10,000**. Living area was given **$120 per square foot**. The file also hides two extras that are not a bath:

- A split foyer with a second bath above grade also has a finished lower level worth $52,000. That lower level is not a column in the file.
- In the townhouses, every 2-story sale has 1 full bath and every 3-story sale has 2 full baths. A "bath" difference and a "stories" difference are the same fact. Two-bath townhouse plans also carry a $20,000 end-unit premium that is not in any column.

250 usable sales, plus 3 records the cleaner should drop (not closed, not arm's length, new construction). The subject in `subject.csv` is a townhouse with 1 full bath. `subject_two_baths.csv` is a colonial with 2 full baths, on the **same sales**.

## What the old tool printed

Same sales. Same model. Only the subject changes. Run with `legacy_config.json` (that switch exists only to show the old behavior — do not use it on an assignment).

| Subject | Full bath, per bath | What the old tool called it |
|---|---:|---|
| Townhouse, 1 bath | $52,502 | SUPPORTED |
| Colonial, 2 baths | $0 | retained, but flat at the subject |

$52,502 is the steep side of a hinge the model put on "full baths." A hinge on a count that only takes 1, 2, or 3 is a step. The townhouse sits on the steep side of the step. The colonial sits on the flat side. Living area, which has many different sizes, stayed near the true $120 per square foot and was not the problem.

The old tool also marked **stories** as supported at about **−$12,300**. That number is the bath tangle showing up again. The true story amount in the file is +$6,000.

## What the tool prints now

Both subjects get the **same** full-bath line, because a count is fit as a straight line instead of a hinge:

**$29,369 per full bath — not for use as a reliable adjustment.**

The line is still calculated, so you can see it. It is not marked supported, and the comp grid carries the same flag. The note on the line says, in short:

- Going from 1 bath to 2 is about $40,000. Going from 2 baths to 3 is about $2,400. One bath adjustment cannot be both.
- In the townhouses, baths and stories are the same fact (48 two-story sales with 1 bath, 30 three-story sales with 2 baths).
- By style, the bath figure is about $2,800 in colonials, about $65,400 in split foyers, and about $33,200 in townhouses.
- Close pairs (similar size, similar year, same stories) say about $62,400 in split foyers and about $2,800 in colonials.

The tool does **not** replace $29,369 with the true $10,000. It does not know the true number. Filling in a "typical" bath adjustment would be a guess. Your judgment still picks the adjustment, or decides the data do not support one.

Living area stays supported (about $105/sf at the townhouse, about $122/sf at the colonial — those are two sides of a size hinge, which is what hinges are for). Garage is one straight line, about $6,500 per space, and it is supported. Stories are not marked supported on this file.

A resample of the file keeps producing a full-bath figure in a fairly narrow band (about $23,000 to $29,000). That only means the file keeps saying the same blended number. It does not mean the number is the price of a bath. The style split above is what shows the blend.

## Files

| File | What it is |
|---|---|
| `sales.csv` | The made-up MLS extract, including a `style` column |
| `subject.csv` | Townhouse, 1 full bath |
| `subject_two_baths.csv` | Colonial, 2 full baths, same sales |
| `comps.txt` | A few of the sales, used as the comp list |
| `truth.json` | The amounts used to build the prices |
| `legacy_config.json` | Old behavior, for this demonstration only |
| `before_adjustments.csv` | Old tool, townhouse subject |
| `before_colonial_adjustments.csv` | Old tool, colonial subject |
| `after_adjustments.csv` | Current tool, townhouse subject |
| `after_colonial_adjustments.csv` | Current tool, colonial subject |
| `after_step_contrasts.csv` | The step, style, and matched-pair figures behind the flag |

Regenerate the sales with `Rscript R/make_unstable_baths_example.R examples/unstable_baths`.

Check the story with `Rscript R/test_adjustment_stability.R`.

No indicated value, reconciled value, or opinion of value is in any output. The figures are adjustment support only (USPAP Advisory Opinion 41).
