<img width="320" src="/docs/images/white-bg-small.png" alt="Logo">

[![Coverage Status](https://coveralls.io/repos/github/Rari-Capital/nova/badge.svg?branch=master)](https://coveralls.io/github/Rari-Capital/nova?branch=master) [![Fuzz Tests](https://github.com/Rari-Capital/nova/actions/workflows/fuzz.yml/badge.svg)](https://github.com/Rari-Capital/nova/actions/workflows/fuzz.yml) [![Integration Tests](https://github.com/Rari-Capital/nova/actions/workflows/integration-tests.yml/badge.svg)](https://github.com/Rari-Capital/nova/actions/workflows/integration-tests.yml) [![Unit Tests](https://github.com/Rari-Capital/nova/actions/workflows/unit-tests.yml/badge.svg)](https://github.com/Rari-Capital/nova/actions/workflows/unit-tests.yml)

Nova gives your **L2 contracts** the power to **read and write to L1** with **minimal latency** and **no trust tradeoffs**.

# Resources

- **[Developer docs + integration guide](https://docs.rari.capital/nova)**

- [Technical specification/whitepaper](/docs/spec.md)

# Contributing

[![Overview](https://lucid.app/publicSegments/view/bcca1b62-7344-4c82-aa5c-3954daf46840/image.png)](https://lucid.app/lucidchart/dca3b0ad-26ed-42f8-a871-1b03b40a2395/view)

## Unit Tests

```bash
npm run unit-tests
```

## Unit Tests With Coverage

After running tests with coverage, an lcov report will be exported to `coverage/index.html`. 

If you are on MacOS you can quickly open the report with `npm run open-coverage-report`.

```bash
npm run coverage
```

## Update Gas Snapshots

If you make a contribution that changes the gas usage of the contracts, run this command before committing. 

```bash
npm run gas-changed
```

## Integration Tests

[You must start up an instance of Optimism's "ops" repo before running integration tests.](https://github.com/ethereum-optimism/optimism/tree/develop/ops)

```bash
npm run integration-tests
```

## Kovan Integration Tests 

You must set the `PRIVATE_KEY` and `KOVAN_RPC_URL` environment variables before running integration tests on Kovan.

```bash
npm run kovan-integration-tests
```

## Fuzz With Echidna

[You must install Echidna before fuzzing.](https://github.com/crytic/echidna#installation)

```bash
npm run fuzz deep {{CONTRACT_NAME}}
```

Replace `{{CONTRACT_NAME}}` with a contract that is fuzzed in `contracts/echidna`. A full list can be found here:

https://github.com/Rari-Capital/nova/blob/master/.github/workflows/fuzz.yml#L13-L14

There are 3 fuzz "modes" setup for this project:

- `deep` enters coverage guided inputs until it is halted manually.

  - It uses coverage guided fuzzing, **which makes it quite slow**.
  - It is the most comprehensive mode (if run for long enough).

- `long` enters random inputs for **5 hours** before halting.

  - It does not use coverage guided fuzzing.
  - Is less comprehensive than `deep`.

- `quick` enters random inputs for **20 minutes** before halting.

  - It does not use coverage guided fuzzing.
  - Is less comprehensive than `long`.

To use any of these modes simply run the command above but replace `deep` with the mode you wish to use (`long`,`quick`, or `deep`).
