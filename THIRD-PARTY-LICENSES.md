# Third-party licenses

`agent-store` is distributed as a static binary that links the Rust crates
listed below, as well as SQLite (compiled from source via the `bundled`
feature of `libsqlite3-sys`).

## SQLite

SQLite is in the [public domain](https://sqlite.org/copyright.html):

> The author disclaims copyright to this source code. In place of a legal
> notice, here is a blessing: May you do good and not evil. May you find
> forgiveness for yourself and forgive others. May you share freely, never
> taking more than you give.

## Rust crates

Every crate below is available under the MIT license (most also offer
Apache-2.0 or other alternatives); this distribution uses each crate under
the MIT license, except `wasi`, which is used under Apache-2.0 WITH
LLVM-exception, and `unicode-ident`, whose Unicode data tables are used
under Unicode-3.0. Some crates in this list are build-time-only
dependencies and do not ship in the binary; they are included for
completeness. Full license and copyright texts are available at each
crate's linked repository and in its packaged source on
[crates.io](https://crates.io).

| Crate | Version | License | Repository |
| --- | --- | --- | --- |
| ahash | 0.8.12 | MIT OR Apache-2.0 | https://github.com/tkaitchuck/ahash |
| bitflags | 2.13.0 | MIT OR Apache-2.0 | https://github.com/bitflags/bitflags |
| cc | 1.2.65 | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| cfg-if | 1.0.4 | MIT OR Apache-2.0 | https://github.com/rust-lang/cfg-if |
| fallible-iterator | 0.3.0 | MIT/Apache-2.0 | https://github.com/sfackler/rust-fallible-iterator |
| fallible-streaming-iterator | 0.1.9 | MIT/Apache-2.0 | https://github.com/sfackler/fallible-streaming-iterator |
| find-msvc-tools | 0.1.9 | MIT OR Apache-2.0 | https://github.com/rust-lang/cc-rs |
| getrandom | 0.2.17 | MIT OR Apache-2.0 | https://github.com/rust-random/getrandom |
| hashbrown | 0.14.5 | MIT OR Apache-2.0 | https://github.com/rust-lang/hashbrown |
| hashlink | 0.9.1 | MIT OR Apache-2.0 | https://github.com/kyren/hashlink |
| itoa | 1.0.18 | MIT OR Apache-2.0 | https://github.com/dtolnay/itoa |
| libc | 0.2.186 | MIT OR Apache-2.0 | https://github.com/rust-lang/libc |
| libsqlite3-sys | 0.30.1 | MIT | https://github.com/rusqlite/rusqlite |
| memchr | 2.8.2 | Unlicense OR MIT | https://github.com/BurntSushi/memchr |
| once_cell | 1.21.4 | MIT OR Apache-2.0 | https://github.com/matklad/once_cell |
| pkg-config | 0.3.33 | MIT OR Apache-2.0 | https://github.com/rust-lang/pkg-config-rs |
| ppv-lite86 | 0.2.21 | MIT OR Apache-2.0 | https://github.com/cryptocorrosion/cryptocorrosion |
| proc-macro2 | 1.0.106 | MIT OR Apache-2.0 | https://github.com/dtolnay/proc-macro2 |
| quote | 1.0.46 | MIT OR Apache-2.0 | https://github.com/dtolnay/quote |
| rand | 0.8.6 | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| rand_chacha | 0.3.1 | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| rand_core | 0.6.4 | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| rusqlite | 0.32.1 | MIT | https://github.com/rusqlite/rusqlite |
| serde | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_core | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_derive | 1.0.228 | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| serde_json | 1.0.150 | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| shlex | 2.0.1 | MIT OR Apache-2.0 | https://github.com/comex/rust-shlex |
| smallvec | 1.15.2 | MIT OR Apache-2.0 | https://github.com/servo/rust-smallvec |
| syn | 2.0.118 | MIT OR Apache-2.0 | https://github.com/dtolnay/syn |
| unicode-ident | 1.0.24 | (MIT OR Apache-2.0) AND Unicode-3.0 | https://github.com/dtolnay/unicode-ident |
| vcpkg | 0.2.15 | MIT/Apache-2.0 | https://github.com/mcgoo/vcpkg-rs |
| version_check | 0.9.5 | MIT/Apache-2.0 | https://github.com/SergioBenitez/version_check |
| wasi | 0.11.1+wasi-snapshot-preview1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT | https://github.com/bytecodealliance/wasi |
| zerocopy | 0.8.52 | BSD-2-Clause OR Apache-2.0 OR MIT | https://github.com/google/zerocopy |
| zerocopy-derive | 0.8.52 | BSD-2-Clause OR Apache-2.0 OR MIT | https://github.com/google/zerocopy |
| zmij | 1.0.21 | MIT | https://github.com/dtolnay/zmij |

## License texts

### MIT License (template)

The following license applies to each crate above used under MIT terms,
with the copyright holder as identified in that crate's repository:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

Apache-2.0 text: <https://www.apache.org/licenses/LICENSE-2.0>.
Unicode-3.0 text: <https://www.unicode.org/license.txt>.
