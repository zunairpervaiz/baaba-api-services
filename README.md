# baaba-api-services

Two packages, published separately:

| Package | What it is | Add it as |
| --- | --- | --- |
| [`baaba_api_handler`](packages/baaba_api_handler) | A typed, functional HTTP client for Flutter, wrapping Dio with `Either`-based errors, token refresh, retries, pinning, named clients and a test double. | `dependencies` |
| [`baaba_api_generator`](packages/baaba_api_generator) | A `build_runner` generator: typed, obfuscated endpoints and environment values from your app's `.env` files. | `dev_dependencies` |

The runnable example, which uses both, is in [`packages/baaba_api_handler/example`](packages/baaba_api_handler/example).

They are sibling packages rather than a pub workspace: a workspace resolves every member together, and Flutter's pinned test dependencies conflict with the versions the generator's tests need. Run commands from inside each package's directory; see [CLAUDE.md](CLAUDE.md) for the full list.
