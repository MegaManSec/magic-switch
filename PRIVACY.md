# Privacy Policy

_Last updated: 27 September 2026_

Magic Switch is a free, open-source macOS app that moves Bluetooth peripherals, such as a Magic Keyboard or Magic Trackpad, between two of your Macs. This policy explains what data the app handles.

## Summary

Magic Switch does not collect, sell or share personal data. It has no accounts, analytics, advertising, tracking or crash reporting, and the developer receives no data from it.

## Data stored on your Mac

The app keeps the following on your Mac so it can work:

- The pairing key shared by your two Macs, stored in the macOS Keychain. **Unpair** in the Pairing tab deletes it.
- The peripherals you've registered: each device's name, type and Bluetooth address.
- Your settings, such as keyboard shortcuts and the display that triggers a switch.
- The IP addresses of devices that repeatedly fail to authenticate, used only to block them temporarily.

## Data shared between your Macs

Magic Switch only talks to the other Mac you paired it with, directly over your local network. The connection is encrypted with the key created during pairing. Your two Macs use it to exchange your list of registered peripherals and switching commands. None of this goes through the developer or any other server.

So your Macs can find each other, the app announces itself on the local network using Bonjour. The announcement includes your Mac's name and a fingerprint of the pairing key (a hash, not the key itself). Other devices on the same network can see it.

## Update checks

The version of Magic Switch downloaded from GitHub checks for updates; the Mac App Store version doesn't, since the App Store updates it.

At most once a day while the app is running, and whenever you click **Check for Updates**, the GitHub version asks GitHub (`api.github.com`) for the latest Magic Switch release. The request contains no identifiers or personal data, but GitHub sees your IP address as it would for any web request. GitHub's handling of that is covered by the [GitHub General Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

Links in the app, such as the release page, the license and GitHub Sponsors, open in your web browser.

## Permissions

- **Bluetooth:** to connect, disconnect and pair your peripherals.
- **Local Network:** to find and communicate with your other Mac.
- **Notifications** (optional): to tell you when a switch fails.

## Changes

Any changes to this policy will be made in this file. Its full history is in this repository's commit log.

## Contact

For questions about this policy, open an issue at <https://github.com/MegaManSec/magic-switch/issues>.
