# Validation record

- Python syntax compilation: PASS.
- Bash syntax check of run.sh: PASS.
- Eight Python regression tests: seven PASS; one optional independent PyCryptodome comparison SKIPPED because that library was not installed. Actual output: reports/offline-validation.txt.
- Solidity source compilation: NOT RUN. Neither Foundry nor solc was available; compiler download failed in the authoring environment.
- Solidity MathSmokeTest execution: NOT RUN.
- Base RPC discovery / real hook identity: NOT RUN SUCCESSFULLY. No observed hook address included.
- Anvil fork permission probes and sale comparisons: NOT RUN.

The presence of a test case is not a passing test result. All synthetic test fixtures are offline fixtures, not statements about the actual pool.
