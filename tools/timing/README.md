# AC-timing analysis

Judges an event log from `sim/tb/timing/` against section 10 of the user
manual. `doc/ac-timing.md` is the account of what it found and why it is built
this way; this is the map.

```sh
make timing                                   # measure and judge this design
make timing-setup                             # where it samples its inputs
python3 tools/timing/specs.py --dump read-write   # the limits, defects resolved
python3 tools/timing/anchors.py                   # what each spec measures between
python3 tools/timing/events.py <log>              # the spacings in one log
python3 tools/timing/analyse.py --brief <logs>    # the verdict
python3 tools/timing/setup_report.py <setup log>  # the input requirements
```

Two debugging aids in the setup testbench, both behind plusargs and both worth
knowing about, because each was added after a measurement lied. `+scan` prints
whether every point across the range matched, which is how you find out that the
bisection's assumption of a single clean transition does not hold; and
`+tracebisect` prints each bisection step, which is how you find out that it
does hold and something else is wrong.

| | |
|---|---|
| `specs.py` | The CSV. Holds the judgement about which printed values to believe — spec 23's 550 ns, spec 46's unit, the two rows numbered 48, the combined `"2, 3"` row, and the three different versions of spec 47 — each with the citation that settles it |
| `anchors.py` | Which two events each specification separates, transcribed from the figure generator with the source line per entry, and the self-check that licenses the clock-anchor convention |
| `events.py` | Reads a log; groups events into bus cycles; resolves anchors to times |
| `feasible.py` | The difference-constraint system, Bellman–Ford, and the skew envelope |
| `analyse.py` | The command line and the verdict |
| `corners.py` | Named pad-delay corners, worked out from the CSV, as tool options |
| `setup_report.py` | Judges the measured input requirements — and note that two of the four limits run the opposite way from the other two |

## The two things worth knowing before changing any of it

**The limits live here and not in SystemVerilog.** The testbenches emit times
and nothing else — no testbench knows what a specification is. That is what
lets a wrong anchor be fixed with a one-line edit and a re-analysis in
milliseconds instead of an xsim elaboration in minutes, and it is what let the
Suska core, which is VHDL, be judged by exactly the same code as ours.

**INFEASIBLE is a proof; FEASIBLE is conditional.** Each transition has its own
delay variable, so unless `--pad-skew` ties them, the solver may give one pin a
large assert delay and a small negate delay. Real pads do not work that way, and
it is not a hypothetical: a two-clock bus cycle passes specification 14's
minimum AS width only by exploiting exactly that. `make timing` therefore
defaults to `--pad-skew 0`, one delay per pin, and prints the looser reading
alongside it.
