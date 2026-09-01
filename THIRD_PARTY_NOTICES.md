# Third-party notices

This file records third-party licensing and attribution information relevant to Meow Core.

## Current source distribution

At the time of the `v0.1.0` framework release, the public source tree was reviewed for embedded third-party copyright / license headers. No third-party source files requiring an additional bundled copyright notice were identified in the maintained source directories.

Meow Core calls HarmonyOS / OpenHarmony / HMS SDK APIs such as the `@kit.*` system interfaces. Those SDKs, tools and platform components are provided separately by their respective rightsholders and remain subject to their own license terms. The MPL-2.0 license in this repository does not relicense those external SDK components.

DevEco Studio may generate build artifacts such as `ResourceTable.ts` / `ResourceTable.h` that contain Huawei copyright and Apache-2.0 notices. These files are generated under `build/` or `entry/build/` and are excluded from the public source repository by `.gitignore`. Their notices must not be removed if such generated files are ever redistributed separately.

## Future imported code

If code is later copied or adapted from a third-party open-source project or official sample, its original license must be checked before inclusion. In particular, for Apache-2.0-licensed sample code:

- preserve the original copyright and license notices in copied or substantially adapted source files;
- include any upstream `NOTICE` content when the upstream distribution requires it;
- document the source project and license in this file;
- do not relicense third-party code in a way that removes upstream obligations.

Using or calling a public SDK API is different from copying the implementation of a sample or library. Only code and assets that Meow Core has the right to license are covered by the repository's MPL-2.0 grant.

## Branding

Meow branding is handled separately. See `BRANDING.md` for the treatment of the Meow name, logo and bundled app icons.
