# Third-party notices

Arkey fetches or depends on the following third-party projects. They are not
relicensed under PolyForm Noncommercial.

| Component | Pinned version | License | Source |
| --- | --- | --- | --- |
| DynamicNotchKit | `cd0b3e52d537db115ad3a9d89601f20e0bee8d27` | MIT | <https://github.com/MrKai77/DynamicNotchKit> |
| node-hid | lockfile version | MIT OR X11 | <https://github.com/node-hid/node-hid> |
| TypeScript | lockfile version, development only | Apache-2.0 | <https://github.com/microsoft/TypeScript> |
| OpenAI Codex CLI / App Server | separately installed by the user; not bundled | Apache-2.0 for the published Codex repository | <https://github.com/openai/codex> |
| Keychron QMK firmware | `618127a725a1773e85f13455602cf6f72ab4de17` | GPL-2.0-only and other file-level licenses | <https://github.com/Keychron/qmk_firmware> |
| QMK Firmware | inherited by the Keychron fork | GPL-2.0 and other file-level licenses | <https://github.com/qmk/qmk_firmware> |
| dfu-util | distributor-selected build; bundled only in release DMGs | GPL-2.0-or-later | <https://github.com/dfu-util/dfu-util> |
| libusb | distributor-selected build; bundled only with dfu-util | LGPL-2.1-or-later | <https://libusb.info/> |

Transitive Node dependencies and exact versions are recorded in
`package-lock.json`. Swift dependencies and revisions are recorded in
`apps/ArkeyMac/Package.resolved`. When distributing a built application or
firmware binary, include all applicable upstream notices and corresponding
source as required by those licenses.

## Codex Micro Lab compatibility references

The optional Lab source contains names, USB identity values, report identifiers,
and behavior labels needed to describe and test interoperability with the
current local ChatGPT Desktop integration. OpenAI, ChatGPT, Codex, Codex Micro,
Work Louder, and related product names and marks belong to their respective
owners.

The repository does **not** include `@worklouder/device-kit-oai`, Work Louder
firmware/source, vendor assets, USB captures, ChatGPT Desktop application code,
or another proprietary SDK. No third-party license, endorsement, USB identity
assignment, device certification, service entitlement, or commercial right is
granted by the compatibility references.

The Lab build's native-facing behavior is version-sensitive and intended only
for local testing on owned hardware. Arkey Report ID `0x07` and its mapping
configuration format are first-party Arkey code covered by the repository's
path-level license map; they are not represented as a vendor protocol.
