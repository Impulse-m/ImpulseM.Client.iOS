# ImpulseM for iOS

This repository contains the ImpulseM client for iOS.

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

## Requirements

Install the Xcode version listed in `versions.json`.

## Configuration

Set `api_id` and `api_hash` in `build-system/template_minimal_development_configuration.json` to the values issued for your build.

## Simulator build (no signing)

```
python3 build-system/Make/Make.py \
    --overrideXcodeVersion \
    --cacheDir="$HOME/bazel-cache" \
    build \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --codesigningInformationPath=build-system/fake-codesigning \
    --disableProvisioningProfiles \
    --configuration=debug_sim_arm64 \
    --buildNumber=10000
```

## Device and IPA builds

Device and IPA builds need codesigning. Copy `build-system/appstore-configuration.json` to a configuration file of your own, and create a codesigning directory modelled on `build-system/fake-codesigning`. Then run the following command with your own paths.

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/bazel-cache" \
    build \
    --configurationPath=path/to/your-configuration.json \
    --codesigningInformationPath=path/to/your-codesigning-directory \
    --buildNumber=100001 \
    --configuration=release_arm64
```

## Tests

The transport and network engine packages have their own test suites. Run them on macOS:

```
cd submodules/ImpulseTransport && swift test
cd submodules/ImpulseNetworkEngine && swift test
```

## License

See the license files that come with the code and with each third-party component.

Third-party code lives under `third-party/` and `submodules/`. Each component keeps its own license files.
