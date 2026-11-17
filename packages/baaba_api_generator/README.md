# baaba_api_generator

Typed, obfuscated API endpoints and environment values for [`baaba_api_handler`](https://pub.dev/packages/baaba_api_handler), generated from the `.env` files in your app.

```dart
await api.get(endpoint: Endpoints.updateOrder(id));
```

Instead of a hand-written wrapper per endpoint, you keep `KEY=value` lines in `env/*.env`, annotate one declaration, and run `build_runner`. Templates with placeholders become methods with matching parameters; plain values become getters; environment values arrive as `String`, `int`, `bool` or `Uri`, checked when you build. Values are obfuscated by default, so a strings search of the compiled app finds none of them.

> **This is obfuscation, not encryption.** It defeats `strings` run over your APK or IPA, and nothing more. Anyone with your source code, a debugger, or an afternoon with a decompiler can recover every value — the key to decode them ships in the same binary. Use it to keep your API's paths and hosts out of casual view. **Real secrets — API keys or credentials that grant access to anything — must never ship in an app**, obfuscated or not; keep them on your server.

## Setup

### 1. Dependencies

```yaml
dependencies:
  baaba_api_handler: ^5.0.0

dev_dependencies:
  build_runner: ^2.4.0
  baaba_api_generator: ^1.0.0
```

The generator needs Dart 3.11 or newer to run (it is only used at build time). The code it writes runs on whatever `baaba_api_handler` supports.

### 2. `build.yaml` — required

build_runner reads only the files listed in your app's `build.yaml` sources, and the default list does not include `env/`. **Without this step the build fails** with "cannot read env/endpoints.env" — the same reason apps using `envied` hit "Environment variable not found".

Create (or extend) `build.yaml` next to your `pubspec.yaml`:

```yaml
targets:
  $default:
    sources:
      - $package$
      - lib/**
      - env/**
      - test/**
      - pubspec.yaml
```

Listing `sources` replaces the defaults, so keep `lib/**` and anything else your other builders need (`web/**`, `bin/**`, …).

### 3. An `.env` file

```properties
# env/endpoints.env
LOGIN=auth/login
UPDATE_ORDER=orders/{orderId}
UPDATE_ORDER_ATTACHMENT=orders/{orderId}/attachments/{attachmentId}

# Positional placeholders, as envied files have them, work too:
LEGACY_STATEMENT=statements/{}/period/{}
```

- `KEY=value`, one per line. `#` starts a comment; blank lines are ignored.
- Quotes around a value are optional: `KEY="a b"` and `KEY='a b'` both work. Unquoted, a `#` after whitespace starts a trailing comment (`https://x/#/a` keeps its `#`). `export KEY=value` is accepted.
- A value may be empty.
- Placeholders: `{name}` (named) or `{}` (positional) — one style per key.

### 4. The annotated declaration

```dart
// lib/api/endpoints.dart
import 'package:baaba_api_handler/baaba_api_handler.dart';

part 'endpoints.g.dart';

@BaabaApiEndpoint(path: 'env/endpoints.env')
typedef Endpoints = _Endpoints;
```

Import `baaba_api_handler` without a prefix — the generated part refers to its names directly.

### 5. Build

```sh
dart run build_runner build      # or: watch
```

### 6. Use it

```dart
Endpoints.login;                                // ApiEndpoint: auth/login
Endpoints.updateOrder(id);                      // orders/42
Endpoints.updateOrderAttachment(id, fileName);  // orders/42/attachments/scan%201.pdf
Endpoints.legacyStatement(account, period);     // statements/…/period/…

await api.get(endpoint: Endpoints.updateOrder(id));
```

| In the `.env` file | Generated |
| --- | --- |
| `LOGIN=auth/login` | `static ApiEndpoint get login` |
| `UPDATE_ORDER=orders/{orderId}` | `static ApiEndpoint updateOrder(Object orderId)` |
| `LEGACY_STATEMENT=statements/{}/period/{}` | `static ApiEndpoint legacyStatement(Object arg1, Object arg2)` |

Keys in `UPPER_SNAKE` become camelCase members; a key already in camelCase is used as written. Every argument is URL-encoded as a single path segment, exactly as [`ApiEndpoint.fill`](https://pub.dev/packages/baaba_api_handler#endpoints-with-parameters) does, and the result joins with `baseUrl` without doubling or dropping a slash. An absolute value (`https://…`) bypasses `baseUrl`.

## Environments

`@BaabaApiEnvironment` reads configuration — hosts, timeouts, flags — into typed fields:

```properties
# env/stage.env
BASE_URL=https://stage.example.com/api
CONNECT_TIMEOUT_SECONDS=30
VERBOSE_LOGGING=true
HUB=wss://stage.example.com/hub
PROXY=
```

```dart
part 'stage_env.g.dart';

@BaabaApiEnvironment(path: 'env/stage.env')
abstract final class StageEnv {
  static final Uri baseUrl = _StageEnv.baseUrl;                    // BASE_URL
  static final int connectTimeoutSeconds = _StageEnv.connectTimeoutSeconds;
  static final bool verboseLogging = _StageEnv.verboseLogging;

  @BaabaApiField(name: 'HUB')
  static final Uri hubUrl = _StageEnv.hubUrl;

  static final String? proxy = _StageEnv.proxy;                   // empty → null
}

ApiServices.init(ApiConfig(
  baseUrl: StageEnv.baseUrl.toString(),
  connectTimeout: Duration(seconds: StageEnv.connectTimeoutSeconds),
));
```

- A field reads the key named by `@BaabaApiField(name: ...)`, or else its name in UPPER_SNAKE case (`baseUrl` → `BASE_URL`), or else its name as written.
- Types: `String`, `int`, `bool` (`true`/`false`, any case), `Uri`. Each value is parsed **when you build**; one that does not parse fails the build, naming the key and line, rather than failing the app at runtime.
- Empty values: a `String` is `''`; a nullable field (`String?`, `int?`, …) is `null`; a non-nullable `int`, `bool` or `Uri` is a build error.
- Write each field's type out: inferred from `_StageEnv.x`, it cannot be resolved while the part is being generated. `const` fields are skipped, so the class can keep helpers of its own.
- On a `typedef` (`typedef StageEnv = _StageEnv;`), every key becomes a `String` getter.

One class per environment file is the simplest arrangement; pick between them in `main()` by flavor.

## Two ways to declare

| | `typedef Endpoints = _Endpoints;` | `abstract final class Endpoints { static final ... = _Endpoints.x; }` |
| --- | --- | --- |
| Members | One per key in the file | One per field you declare |
| `@BaabaApiEndpoint` | Getters, and methods taking the placeholders | Unfilled `ApiEndpoint` templates — call `.fill([...])` |
| `@BaabaApiEnvironment` | All `String` | Typed by the field |
| Missing key | — | Build error |

The typedef form is shortest and is what you want for endpoints. The class form is the shape `envied` uses, and is what you want for typed environments.

## Moving over from envied

Your `.env` files work unchanged — `{}` placeholders included. Change the annotations:

```dart
// Before
@Envied(path: 'env/endpoints.env', obfuscate: true)
abstract final class Endpoints {
  @EnviedField(varName: 'UPDATE_ORDER')
  static final String updateOrder = _Endpoints.updateOrder;
}

// After — same shape, still compiles where the code used Endpoints.updateOrder
@BaabaApiEndpoint(path: 'env/endpoints.env')
abstract final class Endpoints {
  @BaabaApiField(name: 'UPDATE_ORDER')
  static final String updateOrder = _Endpoints.updateOrder;
}

// Or, to drop the hand-written wrappers too:
@BaabaApiEndpoint(path: 'env/endpoints.env')
typedef Endpoints = _Endpoints;
```

A field without `@BaabaApiField` reads `UPPER_SNAKE` first and then its own name, so a field that relied on envied's default (`varName` = field name) still finds its key. Remove `envied` and `envied_generator` from your `pubspec.yaml` and delete the old `*.g.dart` files before rebuilding.

## Obfuscation

On by default (`obfuscate: true`), since hiding the values is the point of the package. For each value the generator draws a fresh key from `Random.secure`, as long as the value, and writes two `const` integer lists: the key, and the value's UTF-16 code units XORed with it. The value is decoded on first use and cached in a `static final`.

- The plain value is never written into the generated file — not in code, not in a comment.
- The same input produces different output on every build.
- A `bool` or `int` is stored at a fixed width, so the list lengths do not give it away. A `String`'s length is visible, as with any XOR scheme.
- Constant integer lists compile to numbers, not text: a `strings` search of a release binary finds neither the values nor fragments of them.
- Parameter names come from named placeholders (`{orderId}` → `orderId`), so those names are visible in the generated source. Use `{}` if even those should not appear.

`obfuscate: false` writes ordinary string literals, for values that do not need hiding.

Again: **obfuscation, not encryption.** See the note at the top.

## Build errors

Every problem fails the build with the file, line and key:

```
env/endpoints.env:7: duplicate key LOGIN (first defined on line 2)
env/endpoints.env:4: UPDATE_ORDER: malformed placeholder: "{" at column 8 is never closed
env/endpoints.env:9: key CLASS gives the name "class", which is not a valid Dart identifier for a public member. Rename the key
env/stage.env has no key BASE_URL for StageEnv.baseUrl. Add "BASE_URL=..." to the file, or name the key the field reads with @BaabaApiField(name: ...).
env/stage.env:3: TIMEOUT must be an int for StageEnv.timeout, got "thirty"
@BaabaApiEndpoint on Endpoints: cannot read "env/endpoints.env". ... add env/** to build.yaml ...
```

Also caught: two keys that generate the same name, mixed `{}` and `{name}` placeholders in one key, a placeholder name that is not a Dart identifier, a malformed line, and an unterminated quote.

## Generated code

For reference — you never edit it, and it changes on every build:

```dart
// ignore_for_file: invalid_use_of_internal_member, unused_element, unused_field, type=lint

abstract final class _Endpoints {
  static final String _v0 = decodeObfuscated(const <int>[...], const <int>[...]);
  static final String _v1 = decodeObfuscated(const <int>[...], const <int>[...]);

  static ApiEndpoint get login => ApiEndpoint(_v0);
  static ApiEndpoint updateOrder(Object orderId) => ApiEndpoint(_v1).fill([orderId]);
}
```

`decodeObfuscated` is `@internal` to `baaba_api_handler`: it exists for generated code, and calling it yourself is flagged by the analyzer.

## License

See [LICENSE](LICENSE).
