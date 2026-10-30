# ImpulseM for iOS

This repository contains the ImpulseM client for iOS.

## Get the Code

```
git clone --recursive -j8 https://github.com/Impulse-m/ImpulseM.Client.iOS.git
```

## Requirements

Install the Xcode version listed in `versions.json`.

## Configuration

Set `api_id` and `api_hash` in `build-system/template_minimal_development_configuration.json` to the values issued for your build.

## Simulator build (no signing)

Generate an Xcode project without provisioning profiles, then build it for a simulator in Xcode:

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --codesigningInformationPath=build-system/fake-codesigning \
    --disableProvisioningProfiles
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
