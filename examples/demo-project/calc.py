"""Tiny calculator used by the agent-merge-train demo project."""


def add(a, b):
    return a + b


def mean(numbers):
    # BUG: floor division truncates, so mean([2, 3]) returns 2 instead of 2.5.
    return sum(numbers) // len(numbers)
