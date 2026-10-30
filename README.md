# ImpulseM for iOS

The ImpulseM client for iOS, built for the ImpulseM platform.

## Get the Code

```
git clone --recursive -j8 https://github.com/Impulse-m/ImpulseM.Client.iOS.git
```

## Build Variables

The client reads its endpoints and links from build-time variables. They are not secrets. Set them in the environment of the build command (or as build properties of the same names). In CI they come from the GitHub organisation variables with the same names.

| Variable | What it does | When it is empty |
|---|---|---|
| `IMPULSEM_RPC_URL` | Base URL of the transport host, for example `https://rpc.example.org`. The client derives its websocket endpoints from it. | CI app builds fail with a clear error. Local and test builds start, make no connection attempt and stay in the not-connected state. |
| `IMPULSEM_SITE_URL` | Base URL of the project website, for example `https://example.org` (no trailing slash). Links to website pages and downloads are built from it. | Website links are hidden, or shown as plain text without a link. |
| `IMPULSEM_LINK_HOST` | Host of public share and deep links, for example `o.example.org`. Used to build share links and to recognise links in text. | No host is recognised statically. Links rely on the server prefix and the app URL scheme. UI that needs a host to build a link is hidden. |
| `IMPULSEM_WEB_URL` | URL of the web client, for example `https://web.example.org/k`. | "Open the web version" links are hidden. |

## Setup Xcode

Install the Xcode version listed in `versions.json` (currently `xcode: 27.1`), directly from https://developer.apple.com/download/applications or using the App Store.

## Adjust Configuration

1. Generate a random identifier:
```
openssl rand -hex 8
```
2. Create a new Xcode project. Use `Telegram` as the Product Name. Use `org.{identifier from step 1}` as the Organization Identifier.
3. Open `Keychain Access` and navigate to `Certificates`. Locate `Apple Development: your@email.address (XXXXXXXXXX)` and double tap the certificate. Under `Details`, locate `Organizational Unit`. This is the Team ID.
4. Edit `build-system/template_minimal_development_configuration.json`. Set `api_id` and `api_hash` to the values issued for your build, and use the data from the previous steps.

## Generate an Xcode project

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

## Tests

The transport and network engine packages have their own test suites. Run them on macOS:

```
cd submodules/ImpulseTransport && swift test
cd submodules/ImpulseNetworkEngine && swift test
```

# Advanced Compilation Guide

## Xcode

1. Copy and edit `build-system/appstore-configuration.json`.
2. Copy `build-system/fake-codesigning`. Create and download provisioning profiles, using the `profiles` folder as a reference for the entitlements.
3. Generate an Xcode project:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=configuration_from_step_1.json \
    --codesigningInformationPath=directory_from_step_2
```

## IPA

1. Repeat the steps from the previous section. Use distribution provisioning profiles.
2. Run:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=...see previous section... \
    --codesigningInformationPath=...see previous section... \
    --buildNumber=100001 \
    --configuration=release_arm64
```

# FAQ

## Xcode is stuck at "build-request.json not updated yet"

Occasionally, you might observe the following message in your build log:
```
"/Users/xxx/Library/Developer/Xcode/DerivedData/Telegram-xxx/Build/Intermediates.noindex/XCBuildData/xxx.xcbuilddata/build-request.json" not updated yet, waiting...
```

Should this occur, simply cancel the ongoing build and initiate a new one.

## `Telegram_xcodeproj: no such package`

Following a system restart, the auto-generated Xcode project might encounter a build failure accompanied by this error:
```
ERROR: Skipping '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj:Telegram_xcodeproj': no such package '@rules_xcodeproj_generated//generator/Telegram/Telegram_xcodeproj': BUILD file not found in directory 'generator/Telegram/Telegram_xcodeproj' of external repository @rules_xcodeproj_generated. Add a BUILD file to a directory to mark it as a package.
```

If you encounter this issue, re-run the project generation steps in the README.


# Tips

## Codesigning is not required for simulator-only builds

Add `--disableProvisioningProfiles`:
```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=path-to-configuration.json \
    --codesigningInformationPath=path-to-provisioning-data \
    --disableProvisioningProfiles
```

## Versions

Each release is built using a specific Xcode version (see `versions.json`). The helper script checks the versions of the installed software and reports an error if they don't match the ones specified in `versions.json`. It is possible to bypass these checks:

```
python3 build-system/Make/Make.py --overrideXcodeVersion build ... # Don't check the version of Xcode
```

## Third-party code

Third-party code lives under `third-party/` and `submodules/`. Each component keeps its own license files.

## License

See the license files that come with the code and with each third-party component.
