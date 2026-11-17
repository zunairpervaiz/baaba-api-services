## 1.0.0

First release.

* **`@BaabaApiEndpoint`** generates typed endpoints from a `.env` file: a key without placeholders becomes a getter (`Endpoints.login`), one with `{name}` placeholders a method with those parameters (`Endpoints.updateOrder(orderId)`), and one with `{}` placeholders a method with `arg1`, `arg2`, … — so `envied` files work unchanged.
* **`@BaabaApiEnvironment`** generates typed configuration — `String`, `int`, `bool` or `Uri`, nullable or not — parsed and checked at build time.
* **`@BaabaApiField(name: ...)`** names the key a field reads; by default `baseUrl` reads `BASE_URL`, then `baseUrl`.
* **Obfuscated by default.** Each value is stored as a fresh `Random.secure` key and the XORed code units, as `const` int lists, decoded lazily on first use. The plain value is never written to the generated file — nor hinted at by its length: a `bool` or `int` is stored at a fixed width — and every build's output differs.
* **Build errors** name the file, line and key: a missing file (with the `build.yaml` `sources` fix spelled out), a missing key, a duplicate key, a malformed placeholder or line, a name that is not a valid Dart identifier, and a value that does not parse as its field's type.
* Both annotations work on a `typedef` (every key) or a class with static fields (the `envied` shape). In a class, `const` fields are left alone, so it can keep helpers of its own; every other static field needs an explicit type and a key.
