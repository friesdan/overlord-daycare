# Fix `mean()` rounding

`mean()` in `calc.py` uses floor division, so `mean([2, 3])` returns `2`
instead of `2.5`. `python3 -m unittest discover` shows `test_mean_fractional`
failing.

Change `mean()` to return the true arithmetic mean (true division). Keep the
change minimal: do not change `add()` and do not change the tests.
