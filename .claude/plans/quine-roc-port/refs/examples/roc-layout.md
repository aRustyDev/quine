# Code Layout

```
.
├── .github/
├── packages/
│   ├── foo/
│   │   ├── docs/
│   │   ├── examples/
│   │   ├── platform/
│   │   ├── src/
│   │   ├── tests/
│   │   └── package.roc
│   ├── bar/
│   │   ├── platform/
│   │   ├── src/
│   │   └── package.roc
│   └── README.md
├── docs/ # `mdbook` documentation
│   ├── src/
│   │   ├── adrs/ # ADRs for the plan/development process. Captures plan/dev decisions, influences longterm ADRs; manage this with `adrs` cli
│   │   │   ├── <category>/
│   │   │   │   └── <sub-category>/
│   │   │   └── <category>/
│   │   ├── core/
│   │   ├── interface/
│   │   ├── ui/
│   │   ├── o11y/
│   │   │   ├── logs/
│   │   │   ├── metrics/
│   │   │   └── traces/
│   │   ├── dependencies/
│   │   ├── complexities/
│   │   ├── cross-cutting/
│   │   ├── contracts/
│   │   ├── taxonomy/
│   │   └── SUMMARY.md
│   └── book.toml
├── README.md
└── build.roc
```
