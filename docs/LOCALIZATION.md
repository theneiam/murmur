# Localization workflow

Murmur uses the Xcode String Catalog at
`Murmur/Resources/Localizable.xcstrings`. English is the source and fallback
language. SwiftUI literal labels are discovered during normal builds because
`SWIFT_EMIT_LOC_STRINGS` is enabled in `project.yml`.

To add or update a translation:

1. Regenerate the project with `xcodegen generate`, build once, and open the
   catalog in Xcode. Review newly discovered English keys and add translator
   comments where the meaning is not obvious.
2. Add the target language in the catalog and translate there, or use Xcode's
   **Product → Export Localizations** and **Import Localizations** workflow.
3. Keep interpolation placeholders and plural rules intact. Do not translate
   product names, bundle identifiers, model folder names, or spoken command
   phrases unless the recognizer and post-processor support the translated
   phrase too.
4. Run the automated checks, launch Murmur in the target language, and inspect
   the menu, onboarding, all Settings tabs, alerts, model download states, and
   the floating status panel. Test long labels and dynamic values.

Adding the catalog provides a translation path; it does not mean the interface
has been translated. Advertise a language only after a fluent contributor has
reviewed its visible strings and layout.
