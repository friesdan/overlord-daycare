import unittest

from calc import add, mean


class TestCalc(unittest.TestCase):
    def test_add(self):
        self.assertEqual(add(2, 3), 5)

    def test_mean_integers(self):
        self.assertEqual(mean([2, 4, 6]), 4)

    def test_mean_fractional(self):
        self.assertEqual(mean([2, 3]), 2.5)


if __name__ == "__main__":
    unittest.main()
