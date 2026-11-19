## 1.0.1

* **A class-form field with a digit in its name finds its key.** `s3Bucket` looked for `S_3_BUCKET` and failed the build against the usual `S3_BUCKET` — the key the typedef form maps to `s3Bucket` — and the same for `oauth2ClientId`, `sha256Pin` and the like. A digit now stays with the word before it, and an acronym ends before the next word (`baseURLPath` → `BASE_URL_PATH`). A file that already uses 1.0.0's spelling (`S_3_BUCKET`) is still read.
* **A class-form field named like generated storage is a build error** rather than generated code that does not compile. A private field such as `static final String _v0` collided with the generator's own `_v0` and declared it twice; the build now names the field and asks for a rename.

## 1.0.0

First release.

* **`@BaabaApiEndpoint`** generates typed endpoints from a `.env` file: a key without placeholders becomes a getter (`Endpoints.login`), one with `{name}` placeholders a method with those parameters (`Endpoints.updateOrder(orderId)`), and one with `{}` placeholders a method with `arg1`, `arg2`, … — so `envied` files work unchanged.
* **`@BaabaApiEnvironment`** generates typed configuration — `String`, `int`, `bool` or `Uri`, nullable or not — parsed and checked at build time.
* **`@BaabaApiField(name: ...)`** names the key a field reads; by default `baseUrl` reads `BASE_URL`, then `baseUrl`.
* **Obfuscated by default.** Each value is stored as a fresh `Random.secure` key and the XORed code units, as `const` int lists, decoded lazily on first use. The plain value is never written to the generated file — nor hinted at by its length: a `bool` or `int` is stored at a fixed width — and every build's output differs.
* **Build errors** name the file, line and key: a missing file (with the `build.yaml` `sources` fix spelled out), a missing key, a duplicate key, a malformed placeholder or line, a name that is not a valid Dart identifier, and a value that does not parse as its field's type.
* Both annotations work on a `typedef` (every key) or a class with static fields (the `envied` shape). In a class, `const` fields are left alone, so it can keep helpers of its own; every other static field needs an explicit type and a key.
