"""Reads sales.csv, aggregates revenue per region, writes summary.csv.
Seeds its own input if sales.csv doesn't exist. Run: python csv_transform.py
"""
import os

import pandas as pd

INPUT = "sales.csv"
OUTPUT = "summary.csv"


def seed_input():
    pd.DataFrame(
        {
            "region": ["north", "south", "north", "east", "south", "east", "north"],
            "units": [10, 4, 7, 12, 9, 3, 5],
            "unit_price": [9.99, 24.50, 9.99, 5.00, 24.50, 5.00, 12.00],
        }
    ).to_csv(INPUT, index=False)
    print(f"seeded {INPUT}")


def main():
    if not os.path.exists(INPUT):
        seed_input()

    df = pd.read_csv(INPUT)
    df["revenue"] = df["units"] * df["unit_price"]
    summary = (
        df.groupby("region")
        .agg(total_units=("units", "sum"), total_revenue=("revenue", "sum"))
        .round(2)
        .sort_values("total_revenue", ascending=False)
    )
    summary.to_csv(OUTPUT)
    print(f"wrote {OUTPUT} ({len(summary)} regions)")
    print(summary.to_string())


if __name__ == "__main__":
    main()
