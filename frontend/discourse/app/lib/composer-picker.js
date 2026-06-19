import EmojiPanel from "discourse/components/composer-picker/emoji-panel";
import GifPanel from "discourse/components/composer-picker/gif-panel";

// Tabs shipped by core. Each tab declares:
//   id        - unique identifier, also persisted as the last-used tab
//   icon      - icon shown in the tab bar
//   title     - i18n key used for the tab's title/aria-label
//   component - the panel rendered when the tab is active. It receives
//               `@onSelect`, `@close`, `@context` and `@term`. When the user
//               makes a choice the panel calls `@onSelect(value)`; the picker
//               forwards `(value, tab)` to its host, which decides what to do
//               with it (the emoji tab is inserted via the emoji helper, every
//               other tab's value is handled by the host's default action -
//               inserted in the composer, sent in chat).
//   priority  - higher sorts first (emoji leads by default)
//   enabled   - ({ siteSettings, owner }) => boolean, evaluated per surface
const CORE_TABS = [
  {
    id: "emoji",
    icon: "far-face-smile",
    title: "composer_picker.tabs.emoji",
    component: EmojiPanel,
    priority: 100,
    enabled: ({ siteSettings }) => siteSettings.enable_emoji,
  },
  {
    id: "gifs",
    icon: "gif",
    title: "composer_picker.tabs.gifs",
    component: GifPanel,
    priority: 90,
    enabled: ({ siteSettings }) => siteSettings.enable_gifs,
  },
];

let customTabs = [];

export function registerComposerPickerTab(tab) {
  customTabs.push(tab);
}

// For tests
export function resetComposerPickerTabs() {
  customTabs = [];
}

// Returns the enabled tabs for the given owner, highest priority first.
export function composerPickerTabs(owner) {
  const siteSettings = owner.lookup("service:site-settings");

  return [...CORE_TABS, ...customTabs]
    .filter((tab) =>
      tab.enabled ? tab.enabled({ siteSettings, owner }) : true
    )
    .sort((a, b) => (b.priority ?? 0) - (a.priority ?? 0));
}
